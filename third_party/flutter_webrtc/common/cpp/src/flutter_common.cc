#include "flutter_common.h"
#include "task_runner.h"

#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>

class MethodCallProxyImpl : public MethodCallProxy {
 public:
  explicit MethodCallProxyImpl(const MethodCall& method_call)
      : method_call_(method_call) {}

  ~MethodCallProxyImpl() {}

  // The name of the method being called.

  const std::string& method_name() const override {
    return method_call_.method_name();
  }

  // The arguments to the method call, or NULL if there are none.
  const EncodableValue* arguments() const override {
    return method_call_.arguments();
  }

 private:
  const MethodCall& method_call_;
};

std::unique_ptr<MethodCallProxy> MethodCallProxy::Create(
    const MethodCall& call) {
  return std::make_unique<MethodCallProxyImpl>(call);
}

class MethodResultProxyImpl : public MethodResultProxy {
 public:
  MethodResultProxyImpl(std::unique_ptr<MethodResult> method_result,
                        TaskRunner* task_runner)
      : method_result_(std::move(method_result)), task_runner_(task_runner) {}
  ~MethodResultProxyImpl() {}

  void Success() override {
    if (!method_result_)
      return;
    if (task_runner_) {
      std::shared_ptr<MethodResult> result(std::move(method_result_));
      task_runner_->EnqueueTask([result]() { result->Success(); });
    } else {
      method_result_->Success();
    }
  }

  void Success(const EncodableValue& val) override {
    if (!method_result_)
      return;
    if (task_runner_) {
      std::shared_ptr<MethodResult> result(std::move(method_result_));
      task_runner_->EnqueueTask([result, val]() { result->Success(val); });
    } else {
      method_result_->Success(val);
    }
  }

  void Error(const std::string& error_code,
             const std::string& error_message,
             const EncodableValue& error_details) override {
    if (!method_result_)
      return;
    if (task_runner_) {
      std::shared_ptr<MethodResult> result(std::move(method_result_));
      task_runner_->EnqueueTask(
          [result, error_code, error_message, error_details]() {
            result->Error(error_code, error_message, error_details);
          });
    } else {
      method_result_->Error(error_code, error_message, error_details);
    }
  }

  void Error(const std::string& error_code,
             const std::string& error_message = "") override {
    if (!method_result_)
      return;
    if (task_runner_) {
      std::shared_ptr<MethodResult> result(std::move(method_result_));
      task_runner_->EnqueueTask([result, error_code, error_message]() {
        result->Error(error_code, error_message);
      });
    } else {
      method_result_->Error(error_code, error_message);
    }
  }

  void NotImplemented() override {
    if (!method_result_)
      return;
    if (task_runner_) {
      std::shared_ptr<MethodResult> result(std::move(method_result_));
      task_runner_->EnqueueTask([result]() { result->NotImplemented(); });
    } else {
      method_result_->NotImplemented();
    }
  }

 private:
  std::unique_ptr<MethodResult> method_result_;
  TaskRunner* task_runner_;
};

std::unique_ptr<MethodResultProxy> MethodResultProxy::Create(
    std::unique_ptr<MethodResult> method_result,
    TaskRunner* task_runner) {
  return std::make_unique<MethodResultProxyImpl>(std::move(method_result),
                                                 task_runner);
}

class EventChannelProxyImpl : public EventChannelProxy {
 public:
  EventChannelProxyImpl(BinaryMessenger* messenger,
                        TaskRunner* task_runner,
                        const std::string& channelName)
      : channel_(std::make_unique<EventChannel>(
            messenger,
            channelName,
            &flutter::StandardMethodCodec::GetInstance())),
        state_(std::make_shared<DispatchState>(task_runner)) {
    std::weak_ptr<DispatchState> weak_state = state_;
    auto handler = std::make_unique<
        flutter::StreamHandlerFunctions<EncodableValue>>(
        [weak_state](
            const EncodableValue* arguments,
            std::unique_ptr<flutter::EventSink<EncodableValue>>&& events)
            -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
          auto state = weak_state.lock();
          if (!state || !state->active.load()) {
            return nullptr;
          }

          std::list<EncodableValue> pending_events;
          std::weak_ptr<EventSink> weak_sink;
          uint64_t generation = 0;
          {
            std::lock_guard<std::mutex> lock(state->mutex);
            if (!state->active.load()) {
              return nullptr;
            }
            state->sink = std::move(events);
            weak_sink = state->sink;
            pending_events.swap(state->event_queue);
            state->on_listen_called = true;
            generation = state->generation;
          }
          for (const auto& event : pending_events) {
            DispatchEvent(weak_state, weak_sink, generation, event);
          }
          return nullptr;
        },
        [weak_state](const EncodableValue* arguments)
            -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
          auto state = weak_state.lock();
          if (!state) {
            return nullptr;
          }
          std::lock_guard<std::mutex> lock(state->mutex);
          state->on_listen_called = false;
          state->sink.reset();
          ++state->generation;
          return nullptr;
        });

    channel_->SetStreamHandler(std::move(handler));
  }

  ~EventChannelProxyImpl() override {
    Deactivate();
    channel_->SetStreamHandler(nullptr);
  }

  void Deactivate() override {
    auto state = state_;
    if (!state || !state->active.exchange(false)) {
      return;
    }
    // Wait until a platform-thread send already in progress has completed.
    // After this lock is acquired no queued callback can enter EventSink.
    std::lock_guard<std::mutex> dispatch_lock(state->dispatch_mutex);
    std::lock_guard<std::mutex> lock(state->mutex);
    ++state->generation;
    state->on_listen_called = false;
    state->sink.reset();
    state->event_queue.clear();
  }

  void Success(const EncodableValue& event, bool cache_event = true) override {
    auto state = state_;
    if (!state || !state->active.load()) {
      return;
    }

    std::weak_ptr<EventSink> weak_sink;
    uint64_t generation = 0;
    {
      std::lock_guard<std::mutex> lock(state->mutex);
      if (!state->active.load()) {
        return;
      }
      generation = state->generation;
      if (state->on_listen_called && state->sink) {
        weak_sink = state->sink;
      } else if (cache_event) {
        state->event_queue.push_back(event);
        return;
      }
    }
    if (!weak_sink.expired()) {
      DispatchEvent(state, weak_sink, generation, event);
    }
  }

 private:
  struct DispatchState {
    explicit DispatchState(TaskRunner* runner) : task_runner(runner) {}

    std::atomic<bool> active{true};
    std::mutex dispatch_mutex;
    std::mutex mutex;
    std::shared_ptr<EventSink> sink;
    std::list<EncodableValue> event_queue;
    bool on_listen_called = false;
    uint64_t generation = 0;
    TaskRunner* task_runner;
  };

  static void DispatchEvent(std::weak_ptr<DispatchState> weak_state,
                            std::weak_ptr<EventSink> weak_sink,
                            uint64_t generation,
                            const EncodableValue& event) {
    auto dispatch = [weak_state, weak_sink, generation, event]() {
      auto state = weak_state.lock();
      if (!state || !state->active.load()) {
        return;
      }

      std::lock_guard<std::mutex> dispatch_lock(state->dispatch_mutex);
      if (!state->active.load()) {
        return;
      }
      {
        std::lock_guard<std::mutex> lock(state->mutex);
        if (!state->active.load() || state->generation != generation) {
          return;
        }
      }
      auto sink = weak_sink.lock();
      if (sink) {
        sink->Success(event);
      }
    };

    auto state = weak_state.lock();
    if (state && state->task_runner) {
      state->task_runner->EnqueueTask(std::move(dispatch));
    } else {
      dispatch();
    }
  }

  std::unique_ptr<EventChannel> channel_;
  std::shared_ptr<DispatchState> state_;
};

std::unique_ptr<EventChannelProxy> EventChannelProxy::Create(
    BinaryMessenger* messenger,
    TaskRunner* task_runner,
    const std::string& channelName) {
  return std::make_unique<EventChannelProxyImpl>(messenger, task_runner,
                                                 channelName);
}
