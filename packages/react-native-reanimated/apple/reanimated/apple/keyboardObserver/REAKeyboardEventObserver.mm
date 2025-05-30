#import <Foundation/Foundation.h>

#import <React/RCTAssert.h>
#import <React/RCTBridgeConstants.h>
#import <React/RCTUtils.h>

#import <reanimated/apple/READisplayLink.h>
#import <reanimated/apple/REASlowAnimations.h>
#import <reanimated/apple/REAUIView.h>
#import <reanimated/apple/keyboardObserver/REAKeyboardEventObserver.h>

typedef NS_ENUM(NSUInteger, KeyboardState) {
  UNKNOWN = 0,
  OPENING = 1,
  OPEN = 2,
  CLOSING = 3,
  CLOSED = 4,
};

@implementation REAKeyboardEventObserver {
  REAUIView *_measuringView;
  NSNumber *_nextListenerId;
  NSMutableDictionary *_listeners;
  READisplayLink *_displayLink;
  KeyboardState _state;
  CFTimeInterval _animationStartTimestamp;
  float _initialKeyboardHeight;
  float _targetKeyboardHeight;
  REAUIView *_keyboardView;
  bool _isKeyboardObserverAttached;
  bool _isInteractiveDismissalCanceled;
}

- (instancetype)init
{
  self = [super init];
  _listeners = [[NSMutableDictionary alloc] init];
  _nextListenerId = @0;
  _state = UNKNOWN;
  _animationStartTimestamp = 0;
  _isKeyboardObserverAttached = false;
  _isInteractiveDismissalCanceled = false;
  NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];

  [notificationCenter addObserver:self
                         selector:@selector(cleanupListeners)
                             name:RCTBridgeDidInvalidateModulesNotification
                           object:nil];
  return self;
}

- (READisplayLink *)getDisplayLink
{
  RCTAssertMainQueue();

  if (!_displayLink) {
    _displayLink = [READisplayLink displayLinkWithTarget:self selector:@selector(updateKeyboardFrame)];
#if !TARGET_OS_OSX
    _displayLink.preferredFramesPerSecond = 120; // will fallback to 60 fps for devices without Pro Motion display
#endif
    [_displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
  }
  return _displayLink;
}

#if TARGET_OS_TV
- (int)subscribeForKeyboardEvents:(KeyboardEventListenerBlock)listener
{
  NSLog(@"Keyboard handling is not supported on tvOS");
  return 0;
}

- (void)unsubscribeFromKeyboardEvents:(int)listenerId
{
  NSLog(@"Keyboard handling is not supported on tvOS");
}

#elif TARGET_OS_OSX

- (int)subscribeForKeyboardEvents:(KeyboardEventListenerBlock)listener
{
  NSLog(@"Keyboard handling is not supported on macOS");
  return 0;
}

- (void)unsubscribeFromKeyboardEvents:(int)listenerId
{
  NSLog(@"Keyboard handling is not supported on macOS");
}

#else

- (void)runListeners:(float)keyboardHeight
{
  for (NSString *key in _listeners.allKeys) {
    ((KeyboardEventListenerBlock)_listeners[key])(_state, keyboardHeight);
  }
}

- (void)runUpdater
{
  [[self getDisplayLink] setPaused:NO];
  _animationStartTimestamp = 0;
}

- (float)getTargetTimestamp
{
  float targetTimestamp = _displayLink.targetTimestamp;
  return reanimated::calculateTimestampWithSlowAnimations(targetTimestamp) * 1000;
}

- (float)estimateProgressForDuration:(float)keyboardAnimationDuration
                                  a1:(float)a1
                                  a2:(float)a2
                                  b1:(float)b1
                                  b2:(float)b2
                                  c1:(float)c1
                                  c2:(float)c2
{
  CFTimeInterval elapsedTime = _displayLink.targetTimestamp - _animationStartTimestamp;
  float timeProgress = elapsedTime / keyboardAnimationDuration;
  timeProgress = fmax(fmin(timeProgress, 1), 0);
  float x = timeProgress;
  float progress = 1 - a1 * pow(1 - x, a2) - b1 * x * pow(1 - x, b2) - c1 * pow(x, 2) * pow(1 - x, c2);
  return progress;
}

- (CGFloat)estimateOpeningKeyboardHeight
{
  /*
    Curve parameters come from estimation: https://www.desmos.com/calculator/ufy5rbucpd
    Animation takes 30 frames, which is 0.48 seconds at 60 fps.
  */
  float progress = [self estimateProgressForDuration:0.48 a1:1 a2:4.62 b1:2.44 b2:9.82 c1:0.22 c2:2.09];
  float animationDistance = _targetKeyboardHeight - _initialKeyboardHeight;
  float currentKeyboardHeight = _initialKeyboardHeight + animationDistance * progress;
  return currentKeyboardHeight;
}

- (CGFloat)estimateClosingKeyboardHeight
{
  /*
    Curve parameters come from estimation: https://www.desmos.com/calculator/vhrhdaopyq
    Animation takes 31 frames, which is 0.496 seconds at 60 fps.
  */
  float progress = [self estimateProgressForDuration:0.496 a1:1 a2:5.65 b1:2.74 b2:8.38 c1:0.93 c2:3.29];
  float currentKeyboardHeight = _initialKeyboardHeight * (1 - progress);
  return currentKeyboardHeight;
}

- (float)getAnimatingKeyboardHeight
{
  if (_animationStartTimestamp == 0) {
    // DisplayLink animations usually start later than CAAnimations.
    _animationStartTimestamp = _displayLink.targetTimestamp - _displayLink.duration;
  }
  CAAnimation *positionAnimation = [_measuringView.layer animationForKey:@"position"];
  float caAnimationBeginTime = [[positionAnimation valueForKey:@"beginTime"] floatValue];
  if (caAnimationBeginTime != 0) {
    /*
      CAAnimations have their own timers, and synchronizing with their timer produces
      better visual effects. The CAAnimation timer is only available from the second
      frame of the animation.
    */
    _animationStartTimestamp = caAnimationBeginTime;
  }

  CGFloat keyboardHeight = 0;
  if (_state == OPENING) {
    keyboardHeight = [self estimateOpeningKeyboardHeight];
  } else if (_state == CLOSING) {
    keyboardHeight = [self estimateClosingKeyboardHeight];
  }
  return keyboardHeight;
}

- (void)updateKeyboardFrame
{
  bool isKeyboardAnimationRunning = [self hasAnyAnimation:_measuringView];
  if (isKeyboardAnimationRunning) {
    CGFloat keyboardHeight = [self getAnimatingKeyboardHeight];
    [self runListeners:keyboardHeight];
  }
}

- (void)keyboardWillChangeFrame:(NSNotification *)notification
{
  NSDictionary *userInfo = [notification userInfo];
  CGRect beginFrame = [[userInfo objectForKey:UIKeyboardFrameBeginUserInfoKey] CGRectValue];
  CGRect endFrame = [[userInfo objectForKey:UIKeyboardFrameEndUserInfoKey] CGRectValue];
  NSTimeInterval animationDuration = [[userInfo objectForKey:UIKeyboardAnimationDurationUserInfoKey] doubleValue];
  auto window = [[[UIApplication sharedApplication] delegate] window];

  /*
   The keyboard frame is in the screen's coordinate space and must first be converted
   to the window coordinate space in order to support Slide Over and Stage Manager on
   iPadOS.
   */
  beginFrame = [window convertRect:beginFrame fromCoordinateSpace:window.screen.coordinateSpace];
  endFrame = [window convertRect:endFrame fromCoordinateSpace:window.screen.coordinateSpace];

  /*
   In some cases, such as when the user has enabled "prefer cross-fade transitions" or
   when the keyboard is floating, the begin or end frame is an empty rectangle. In
   such cases we should treat the keyboard as closed, rather than at (0, 0).
   */
  CGRect beginFrameIntersection = CGRectIntersection(window.bounds, beginFrame);
  _initialKeyboardHeight =
      CGRectIsEmpty(beginFrameIntersection) ? 0 : CGRectGetMaxY(window.bounds) - CGRectGetMinY(beginFrameIntersection);

  CGRect endFrameIntersection = CGRectIntersection(window.bounds, endFrame);
  _targetKeyboardHeight =
      CGRectIsEmpty(endFrameIntersection) ? 0 : CGRectGetMaxY(window.bounds) - CGRectGetMinY(endFrameIntersection);

  bool forceAnimation = false;
  auto keyboardView = [self getKeyboardView];
  if (_state == CLOSING) {
    _targetKeyboardHeight = 0;
  } else if (_isInteractiveDismissalCanceled && keyboardView) {
    // Prefer the keyboard view frame over notification frame which may not be current.
    beginFrameIntersection = CGRectIntersection(window.bounds, keyboardView.frame);
    _initialKeyboardHeight = CGRectIsEmpty(beginFrameIntersection)
        ? 0
        : CGRectGetMaxY(window.bounds) - CGRectGetMinY(beginFrameIntersection);
    forceAnimation = true;
  }
  _isInteractiveDismissalCanceled = false;

  bool hasKeyboardAnimation = [self hasAnyAnimation:keyboardView];
  if (hasKeyboardAnimation || forceAnimation) {
    _measuringView.frame = CGRectMake(0, -1, 0, _initialKeyboardHeight);
    [UIView animateWithDuration:animationDuration
                     animations:^{
                       self->_measuringView.frame = CGRectMake(0, -1, 0, self->_targetKeyboardHeight);
                     }];
    [self runUpdater];
  }
}

- (int)subscribeForKeyboardEvents:(KeyboardEventListenerBlock)listener
{
  NSNumber *listenerId = [_nextListenerId copy];
  _nextListenerId = [NSNumber numberWithInt:[_nextListenerId intValue] + 1];
  RCTExecuteOnMainQueue(^() {
    if (!self->_measuringView) {
      self->_measuringView = [[UIView alloc] initWithFrame:CGRectMake(0, -1, 0, 0)];
      UIWindow *keyWindow = [[[UIApplication sharedApplication] delegate] window];
      [keyWindow addSubview:self->_measuringView];
    }
    if ([self->_listeners count] == 0) {
      NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
      [notificationCenter addObserver:self
                             selector:@selector(keyboardWillShow:)
                                 name:UIKeyboardWillShowNotification
                               object:nil];
      [notificationCenter addObserver:self
                             selector:@selector(keyboardDidShow:)
                                 name:UIKeyboardDidShowNotification
                               object:nil];
      [notificationCenter addObserver:self
                             selector:@selector(keyboardWillHide:)
                                 name:UIKeyboardWillHideNotification
                               object:nil];
      [notificationCenter addObserver:self
                             selector:@selector(keyboardDidHide:)
                                 name:UIKeyboardDidHideNotification
                               object:nil];
    }

    [self->_listeners setObject:listener forKey:listenerId];
  });
  return [listenerId intValue];
}

- (void)unsubscribeFromKeyboardEvents:(int)listenerId
{
  RCTExecuteOnMainQueue(^() {
    NSNumber *_listenerId = [NSNumber numberWithInt:listenerId];
    [self->_listeners removeObjectForKey:_listenerId];
    if ([self->_listeners count] == 0) {
      NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
      [notificationCenter removeObserver:self name:UIKeyboardWillShowNotification object:nil];
      [notificationCenter removeObserver:self name:UIKeyboardDidShowNotification object:nil];
      [notificationCenter removeObserver:self name:UIKeyboardWillHideNotification object:nil];
      [notificationCenter removeObserver:self name:UIKeyboardDidHideNotification object:nil];
    }
  });
}

- (void)cleanupListeners
{
  RCTUnsafeExecuteOnMainQueueSync(^() {
    [self->_listeners removeAllObjects];
    [[self getDisplayLink] invalidate];
    self->_displayLink = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
  });
}

- (void)keyboardWillShow:(NSNotification *)notification
{
  _state = OPENING;
  [self keyboardWillChangeFrame:notification];
}

- (void)keyboardDidShow:(NSNotification *)notification
{
  [[self getDisplayLink] setPaused:YES];

  auto window = [[[UIApplication sharedApplication] delegate] window];
  auto keyboardView = [self getKeyboardView];
  if (keyboardView) {
    CGRect frameIntersection = CGRectIntersection(window.bounds, keyboardView.frame);
    _targetKeyboardHeight =
        CGRectIsEmpty(frameIntersection) ? 0 : CGRectGetMaxY(window.bounds) - CGRectGetMinY(frameIntersection);
  }
  _state = OPEN;
  [self runListeners:_targetKeyboardHeight];

  if (_isKeyboardObserverAttached) {
    return;
  }
  if (keyboardView) {
    [_keyboardView addObserver:self
                    forKeyPath:@"center"
                       options:NSKeyValueObservingOptionOld | NSKeyValueObservingOptionNew
                       context:nil];
    _isKeyboardObserverAttached = true;
  }
}

- (void)keyboardWillHide:(NSNotification *)notification
{
  if (_isKeyboardObserverAttached) {
    [_keyboardView removeObserver:self forKeyPath:@"center"];
    _isKeyboardObserverAttached = false;
  }

  _state = CLOSING;
  [self keyboardWillChangeFrame:notification];
}

- (void)keyboardDidHide:(NSNotification *)notification
{
  [[self getDisplayLink] setPaused:YES];

  _targetKeyboardHeight = 0;
  _state = CLOSED;
  [self runListeners:_targetKeyboardHeight];
}

- (void)updateKeyboardHeightDuringInteractiveDismiss:(CGPoint)oldKeyboardFrame
                                    newKeyboardFrame:(CGPoint)newKeyboardFrame
{
  auto keyboardView = [self getKeyboardView];
  if (!keyboardView) {
    return;
  }

  bool hasKeyboardAnimation = [self hasAnyAnimation:keyboardView];
  float keyboardHeight = keyboardView.frame.size.height;
  /*
   If the keyboard is animating, height will be updated by the notification observers.
   If the keyboard state is CLOSED, height is 0, or the keyboard is floating (keyboard
   width != window width), don't update to prevent jumping to intermediate state.
   */
  if (hasKeyboardAnimation || _state == CLOSED || keyboardHeight == 0 ||
      CGRectGetWidth(keyboardView.frame) != CGRectGetWidth(keyboardView.window.bounds)) {
    return;
  }

  float windowHeight = keyboardView.window.bounds.size.height;
  float visibleKeyboardHeight = windowHeight - (newKeyboardFrame.y - keyboardHeight / 2);
  if (oldKeyboardFrame.y > newKeyboardFrame.y) {
    _state = OPENING;
    _isInteractiveDismissalCanceled = true;
  } else if (oldKeyboardFrame.y < newKeyboardFrame.y) {
    _state = CLOSING;
    _isInteractiveDismissalCanceled = false;
  }
  [self runListeners:visibleKeyboardHeight];
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey, id> *)change
                       context:(void *)context
{
  if ([keyPath isEqualToString:@"center"]) {
    CGPoint oldKeyboardFrame = [change[NSKeyValueChangeOldKey] CGPointValue];
    CGPoint newKeyboardFrame = [change[NSKeyValueChangeNewKey] CGPointValue];
    [self updateKeyboardHeightDuringInteractiveDismiss:oldKeyboardFrame newKeyboardFrame:newKeyboardFrame];
  }
}

- (bool)hasAnyAnimation:(REAUIView *)view
{
  return view.layer.presentationLayer.animationKeys.count != 0;
  ;
}

- (REAUIView *_Nullable)findClass:(NSString *)className inViewsList:(NSArray<REAUIView *> *)viewList
{
  for (UIWindow *view in viewList) {
    if ([NSStringFromClass([view class]) isEqual:className]) {
      return view;
    }
  }
  return nil;
}

// Inspired by: https://stackoverflow.com/questions/32598490
- (REAUIView *_Nullable)getKeyboardView
{
  if (_keyboardView) {
    return _keyboardView;
  }
  NSArray<UIWindow *> *windows = [UIApplication sharedApplication].windows;
  auto window = [self findClass:@"UITextEffectsWindow" inViewsList:windows];
  auto keyboardContainer = [self findClass:@"UIInputSetContainerView" inViewsList:window.subviews];
  _keyboardView = [self findClass:@"UIInputSetHostView" inViewsList:keyboardContainer.subviews];
  return _keyboardView;
}

#endif

@end
