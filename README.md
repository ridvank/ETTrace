# ETTrace 👽

Locally measure performance of your app, without Xcode or Instruments.

## Building and Installing

Modify the code signing team in `ETTrace/ETTrace.xcworkspace` to your own team. Run `./build.sh` to build the xcframework `ETTrace.xcframework`. Link the xcframework to your app.

## Using

Launch your app and run `./ETTraceRunner`. After profiling, the result will be displayed on https://emergetools.com/flamegraph

