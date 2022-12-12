//
//  Constructor.m
//  PerfAnalysis
//
//  Created by Noah Martin on 11/23/22.
//

#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import "EMGWriteLibraries.h"
#import <vector>
#import <mutex>
#import <mach/mach.h>
#import <sys/sysctl.h>
#import <mach-o/arch.h>

#import "PerfAnalysis.h"

@implementation EMGPerfAnalysis

static thread_t sMainMachThread = {0};
static const int kMaxFramesPerStack = 512;
static NSThread *sStackRecordingThread = nil;
typedef struct {
    CFTimeInterval time;
    uint64_t frameCount;
    uintptr_t frames[kMaxFramesPerStack];
} Stack;
static std::vector<Stack> *sStacks;
static std::mutex sStacksLock;

static dispatch_queue_t fileEventsQueue;

extern "C" {
void FIRCLSWriteThreadStack(thread_t thread, uintptr_t *frames, uint64_t framesCapacity, uint64_t *framesWritten);
}

+ (void)recordStack
{
    Stack stack;
    thread_suspend(sMainMachThread);
    stack.time = CACurrentMediaTime();
    FIRCLSWriteThreadStack(sMainMachThread, stack.frames, kMaxFramesPerStack, &(stack.frameCount));
    thread_resume(sMainMachThread);
    sStacksLock.lock();
    try {
      sStacks->emplace_back(stack);
    } catch (const std::length_error& le) {
      fflush(stdout);
      fflush(stderr);
      throw le;
    }
    sStacksLock.unlock();
}

+ (void)setupStackRecording
{
    // Make sure that +recordStack is always called on the same (non-main) thread.
    // This is because a Process keeps its own "current thread" variable which we need
    // to keep separate
    // from the main thread. This is because unwinding itself from the main thread
    // requires Crashlyics to use a hack, and because the stack recording would show up
    // in the trace. The current strategy is to sleep for 4.5 ms because
    // usleep is guaranteed to sleep more than that, in practice ~5ms. We could use a
    // dispatch_timer, which at least tries to compensate for drift etc., but the
    // timer's queue could theoretically end up run on the main thread
    sStacks = new std::vector<Stack>;
    sStacks->reserve(400);
    sStackRecordingThread = [[NSThread alloc] initWithBlock:^{
        NSThread *thread = [NSThread currentThread];
        while (!thread.cancelled) {
            [self recordStack];
            usleep(4500);
        }
    }];
    sStackRecordingThread.qualityOfService = NSQualityOfServiceUserInteractive;
    [sStackRecordingThread start];
}

static NSFileHandle* handle;
static dispatch_source_t source;

+ (void)startObserving {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSURL *documentsURL = [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask][0];
        NSURL *emergeDirectoryURL = [documentsURL URLByAppendingPathComponent:@"emerge-perf-analysis"];
        if (![[NSFileManager defaultManager] fileExistsAtPath:emergeDirectoryURL.path isDirectory:NULL]) {
            [[NSFileManager defaultManager] createDirectoryAtURL:emergeDirectoryURL withIntermediateDirectories:YES attributes:nil error:nil];
        }
        NSURL *outputURL = [emergeDirectoryURL URLByAppendingPathComponent:@"state.json"];
        handle = [NSFileHandle fileHandleForReadingAtPath:outputURL.path];
        source = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, handle.fileDescriptor, DISPATCH_VNODE_WRITE, fileEventsQueue);
        dispatch_source_set_event_handler(source, ^{
            NSData *fileData = [NSData dataWithContentsOfFile:outputURL.path];
            if (fileData) {
                NSError *error = nil;
                NSDictionary *state = [NSJSONSerialization JSONObjectWithData:fileData options:NULL error:&error];
                if (!error) {
                    NSLog(@"Parsed perf analysis state");
                    BOOL running = [state[@"running"] boolValue];
                    BOOL runAtStartup = [state[@"runAtStartup"] boolValue];
                    [[NSUserDefaults standardUserDefaults] setBool:runAtStartup forKey:@"runAtStartup"];
                    if (runAtStartup) {
                        exit(0);
                    }
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (running && sStackRecordingThread == nil) {
                            [self setupStackRecording];
                        } else if (!running && sStackRecordingThread) {
                            [sStackRecordingThread cancel];
                            sStackRecordingThread = nil;
                            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                                [EMGPerfAnalysis stopRecording];
                            });
                        }
                    });
                } else {
                    NSLog(@"Error parsing perf analysis dictionary %@", error);
                }
            }
        });
        dispatch_resume(source);
        NSLog(@"started");
    });
}

+ (BOOL)isRunningOnSimulator
{
#if TARGET_OS_SIMULATOR
    return YES;
#else
    return NO;
#endif
}

+ (NSString *)osBuild {
    int mib[2] = {CTL_KERN, KERN_OSVERSION};
    u_int namelen = sizeof(mib) / sizeof(mib[0]);
    size_t bufferSize = 0;

    NSString *osBuildVersion = nil;

    // Get the size for the buffer
    sysctl(mib, namelen, NULL, &bufferSize, NULL, 0);

    u_char buildBuffer[bufferSize];
    int result = sysctl(mib, namelen, buildBuffer, &bufferSize, NULL, 0);

    if (result >= 0) {
        osBuildVersion = [[NSString alloc] initWithBytes:buildBuffer length:bufferSize encoding:NSUTF8StringEncoding];
    }

    return osBuildVersion;
}

+ (void)stopRecording {
    NSLog(@"************** EMG done");
    sStacksLock.lock();
    NSMutableArray <NSDictionary <NSString *, id> *> *stacks = [NSMutableArray array];
    for (const auto &cStack : *sStacks) {
        NSMutableArray <NSNumber *> *stack = [NSMutableArray array];
        // Add the addrs in reverse order so that they start with the lowest frame, e.g. `start`
        for (int j = (int)cStack.frameCount - 1; j >= 0; j--) {
            [stack addObject:@((NSUInteger)cStack.frames[j])];
        }
        NSDictionary *stackDictionary = @{
            @"stack": [stack copy],
            @"time": @(cStack.time)
        };
        [stacks addObject:stackDictionary];
    }
    sStacks->clear();
    sStacksLock.unlock();
    const NXArchInfo *archInfo = NXGetLocalArchInfo();
    NSString *cpuType = [NSString stringWithUTF8String:archInfo->description];
    NSMutableDictionary *info = [@{
        @"stacks": stacks,
        @"libraryInfo": EMGLibrariesData(),
        @"isSimulator": @([self isRunningOnSimulator]),
        @"osBuild": [self osBuild],
        @"cpuType": cpuType
    } mutableCopy];
    
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:info options:0 error:&error];
    if (error) {
        @throw error;
    }
    NSURL *documentsURL = [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask][0];
    NSURL *emergeDirectoryURL = [documentsURL URLByAppendingPathComponent:@"emerge-output"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:emergeDirectoryURL.path isDirectory:NULL]) {
        [[NSFileManager defaultManager] createDirectoryAtURL:emergeDirectoryURL withIntermediateDirectories:YES attributes:nil error:nil];
    }
    NSURL *outputURL = [emergeDirectoryURL URLByAppendingPathComponent:@"output.json"];
    [data writeToURL:outputURL atomically:YES];
}

+ (void)load {
    sMainMachThread = mach_thread_self();
    fileEventsQueue = dispatch_queue_create("com.emerge.file_queue", DISPATCH_QUEUE_SERIAL);
    EMGBeginCollectingLibraries();
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"runAtStartup"]) {
        [EMGPerfAnalysis setupStackRecording];
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"runAtStartup"];
    }
    [EMGPerfAnalysis startObserving];
}

@end