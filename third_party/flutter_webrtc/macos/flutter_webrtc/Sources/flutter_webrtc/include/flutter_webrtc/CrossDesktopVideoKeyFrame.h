#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Advances the process-wide desktop-video key-frame generation.
///
/// CrossDesktopRemote currently owns one outgoing desktop video sender per
/// process. Every active encoder consumes a generation at most once, which is
/// also safe if WebRTC temporarily creates a replacement encoder while
/// adapting resolution.
FOUNDATION_EXPORT NSUInteger CDRRequestDesktopVideoKeyFrame(void);

/// Returns the latest requested desktop-video key-frame generation.
FOUNDATION_EXPORT NSUInteger CDRDesktopVideoKeyFrameGeneration(void);

NS_ASSUME_NONNULL_END
