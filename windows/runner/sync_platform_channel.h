#ifndef RUNNER_SYNC_PLATFORM_CHANNEL_H_
#define RUNNER_SYNC_PLATFORM_CHANNEL_H_

#include <flutter/flutter_engine.h>
#include <flutter/method_channel.h>

#include <functional>
#include <memory>

#include <windows.h>

class SyncPlatformChannel {
 public:
  SyncPlatformChannel(flutter::FlutterEngine* engine, HWND window,
                      std::function<void()> allow_close);
  ~SyncPlatformChannel();

  void RequestWindowClose();

 private:
  void HandleMethodCall(const flutter::MethodCall<>& call,
                        std::unique_ptr<flutter::MethodResult<>> result);

  HWND window_;
  std::function<void()> allow_close_;
  std::unique_ptr<flutter::MethodChannel<>> channel_;
};

#endif  // RUNNER_SYNC_PLATFORM_CHANNEL_H_
