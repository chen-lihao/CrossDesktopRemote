#import "CrossDesktopVideoKeyFrame.h"

#import <os/lock.h>

static os_unfair_lock gCDRKeyFrameLock = OS_UNFAIR_LOCK_INIT;
static NSUInteger gCDRKeyFrameGeneration = 0;

NSUInteger CDRRequestDesktopVideoKeyFrame(void) {
  os_unfair_lock_lock(&gCDRKeyFrameLock);
  gCDRKeyFrameGeneration += 1;
  const NSUInteger generation = gCDRKeyFrameGeneration;
  os_unfair_lock_unlock(&gCDRKeyFrameLock);
  return generation;
}

NSUInteger CDRDesktopVideoKeyFrameGeneration(void) {
  os_unfair_lock_lock(&gCDRKeyFrameLock);
  const NSUInteger generation = gCDRKeyFrameGeneration;
  os_unfair_lock_unlock(&gCDRKeyFrameLock);
  return generation;
}
