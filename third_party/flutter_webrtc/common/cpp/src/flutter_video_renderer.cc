#include "flutter_video_renderer.h"

#include <limits>
#include <new>

namespace flutter_webrtc_plugin {

FlutterVideoRenderer::~FlutterVideoRenderer() {}

void FlutterVideoRenderer::initialize(
    TextureRegistrar* registrar,
    BinaryMessenger* messenger,
    TaskRunner* task_runner,
    std::unique_ptr<flutter::TextureVariant> texture,
    int64_t trxture_id) {
  registrar_ = registrar;
  texture_ = std::move(texture);
  texture_id_ = trxture_id;
  std::string channel_name =
      "FlutterWebRTC/Texture" + std::to_string(texture_id_);
  event_channel_ = EventChannelProxy::Create(messenger, task_runner, channel_name);
}

const FlutterDesktopPixelBuffer* FlutterVideoRenderer::CopyPixelBuffer(
    size_t width,
    size_t height) const {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!frame_) {
    return nullptr;
  }

  const size_t frame_width = static_cast<size_t>(frame_->width());
  const size_t frame_height = static_cast<size_t>(frame_->height());
  constexpr size_t kBytesPerPixel = 4;
  if (frame_width == 0 || frame_height == 0 ||
      frame_width >
          std::numeric_limits<size_t>::max() / frame_height / kBytesPerPixel) {
    return nullptr;
  }
  const size_t buffer_size = frame_width * frame_height * kBytesPerPixel;

  if (!active_pixel_buffer_ ||
      active_pixel_buffer_->descriptor.width != frame_width ||
      active_pixel_buffer_->descriptor.height != frame_height ||
      active_pixel_buffer_->capacity < buffer_size) {
    if (active_pixel_buffer_) {
      retired_pixel_buffers_.push_back(active_pixel_buffer_);
    }
    auto reusable = retired_pixel_buffers_.end();
    for (auto it = retired_pixel_buffers_.begin();
         it != retired_pixel_buffers_.end(); ++it) {
      if ((*it)->descriptor.width == frame_width &&
          (*it)->descriptor.height == frame_height &&
          (*it)->capacity >= buffer_size) {
        reusable = it;
        break;
      }
    }
    if (reusable != retired_pixel_buffers_.end()) {
      active_pixel_buffer_ = *reusable;
      retired_pixel_buffers_.erase(reusable);
    } else {
      auto storage = std::make_shared<PixelBufferStorage>();
      storage->bytes.reset(new (std::nothrow) uint8_t[buffer_size]);
      if (!storage->bytes) {
        return nullptr;
      }
      storage->capacity = buffer_size;
      storage->descriptor.width = frame_width;
      storage->descriptor.height = frame_height;
      storage->descriptor.buffer = storage->bytes.get();
      active_pixel_buffer_ = std::move(storage);
    }
  }

  frame_->ConvertToARGB(
      RTCVideoFrame::Type::kABGR, active_pixel_buffer_->bytes.get(), 0,
      static_cast<int>(frame_width), static_cast<int>(frame_height));
  return &active_pixel_buffer_->descriptor;
}

void FlutterVideoRenderer::OnFrame(scoped_refptr<RTCVideoFrame> frame) {
  bool send_first_frame = false;
  bool send_rotation = false;
  bool send_size = false;
  const auto frame_rotation = frame->rotation();
  const auto frame_width = frame->width();
  const auto frame_height = frame->height();
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!first_frame_rendered) {
      first_frame_rendered = true;
      send_first_frame = true;
    }
    if (rotation_ != frame_rotation) {
      rotation_ = frame_rotation;
      send_rotation = true;
    }
    if (last_frame_size_.width != static_cast<size_t>(frame_width) ||
        last_frame_size_.height != static_cast<size_t>(frame_height)) {
      last_frame_size_ = {static_cast<size_t>(frame_width),
                          static_cast<size_t>(frame_height)};
      send_size = true;
    }
    frame_ = frame;
  }

  if (send_first_frame) {
    EncodableMap params;
    params[EncodableValue("event")] = "didFirstFrameRendered";
    params[EncodableValue("id")] = EncodableValue(texture_id_);
    event_channel_->Success(EncodableValue(params));
  }
  if (send_rotation) {
    EncodableMap params;
    params[EncodableValue("event")] = "didTextureChangeRotation";
    params[EncodableValue("id")] = EncodableValue(texture_id_);
    params[EncodableValue("rotation")] =
        EncodableValue(static_cast<int32_t>(frame_rotation));
    event_channel_->Success(EncodableValue(params));
  }
  if (send_size) {
    EncodableMap params;
    params[EncodableValue("event")] = "didTextureChangeVideoSize";
    params[EncodableValue("id")] = EncodableValue(texture_id_);
    params[EncodableValue("width")] =
        EncodableValue(static_cast<int32_t>(frame_width));
    params[EncodableValue("height")] =
        EncodableValue(static_cast<int32_t>(frame_height));
    event_channel_->Success(EncodableValue(params));
  }
  registrar_->MarkTextureFrameAvailable(texture_id_);
}

void FlutterVideoRenderer::SetVideoTrack(scoped_refptr<RTCVideoTrack> track) {
  scoped_refptr<RTCVideoTrack> previous_track;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (track_ == track) {
      return;
    }
    previous_track = track_;
  }
  if (previous_track) {
    previous_track->RemoveRenderer(this);
  }
  {
    std::lock_guard<std::mutex> lock(mutex_);
    track_ = track;
    last_frame_size_ = {0, 0};
    first_frame_rendered = false;
    frame_ = nullptr;
  }
  if (track) {
    track->AddRenderer(this);
  }
}

bool FlutterVideoRenderer::CheckMediaStream(std::string mediaId) {
  if (0 == mediaId.size() || 0 == media_stream_id.size()) {
    return false;
  }
  return mediaId == media_stream_id;
}

bool FlutterVideoRenderer::CheckVideoTrack(std::string mediaId) {
  if (mediaId.empty()) {
    return false;
  }
  std::lock_guard<std::mutex> lock(mutex_);
  return track_ && mediaId == track_->id().std_string();
}

FlutterVideoRendererManager::FlutterVideoRendererManager(
    FlutterWebRTCBase* base)
    : base_(base) {}

void FlutterVideoRendererManager::CreateVideoRendererTexture(
    std::unique_ptr<MethodResultProxy> result) {
  auto texture = new RefCountedObject<FlutterVideoRenderer>();
  auto textureVariant =
      std::make_unique<flutter::TextureVariant>(flutter::PixelBufferTexture(
          [texture](size_t width,
                    size_t height) -> const FlutterDesktopPixelBuffer* {
            return texture->CopyPixelBuffer(width, height);
          }));

  auto texture_id = base_->textures_->RegisterTexture(textureVariant.get());
  texture->initialize(base_->textures_, base_->messenger_, base_->task_runner_,
                      std::move(textureVariant), texture_id);
  renderers_[texture_id] = texture;
  EncodableMap params;
  params[EncodableValue("textureId")] = EncodableValue(texture_id);
  result->Success(EncodableValue(params));
}

void FlutterVideoRendererManager::VideoRendererSetSrcObject(
    int64_t texture_id,
    const std::string& stream_id,
    const std::string& owner_tag,
    const std::string& track_id) {
  scoped_refptr<RTCMediaStream> stream =
      base_->MediaStreamForId(stream_id, owner_tag);

  auto it = renderers_.find(texture_id);
  if (it != renderers_.end()) {
    FlutterVideoRenderer* renderer = it->second.get();
    if (stream.get()) {
      auto video_tracks = stream->video_tracks();
      if (video_tracks.size() > 0) {
        if (track_id == std::string()) {
          renderer->SetVideoTrack(video_tracks[0]);
        } else {
          for (auto track : video_tracks.std_vector()) {
            if (track->id().std_string() == track_id) {
              renderer->SetVideoTrack(track);
              break;
            }
          }
        }
        renderer->media_stream_id = stream_id;
      }
    } else {
      renderer->SetVideoTrack(nullptr);
    }
  }
}

void FlutterVideoRendererManager::VideoRendererDispose(
    int64_t texture_id,
    std::unique_ptr<MethodResultProxy> result) {
  auto it = renderers_.find(texture_id);
  if (it != renderers_.end()) {
    it->second->SetVideoTrack(nullptr);
#if defined(_WINDOWS)
    base_->textures_->UnregisterTexture(texture_id,
                                        [&, it] { renderers_.erase(it); });
#else
    base_->textures_->UnregisterTexture(texture_id);
    renderers_.erase(it);
#endif
    result->Success();
    return;
  }
  result->Error("VideoRendererDisposeFailed",
                "VideoRendererDispose() texture not found!");
}

}  // namespace flutter_webrtc_plugin
