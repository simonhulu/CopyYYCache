//
//  YYMemoryCache.h
//  CopyYYCache
//
//  Created by szhang on 14/12/2015.
//  Copyright © 2015 szhang. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface YYMemoryCache : NSObject
/**
 The auto trim check time interval in seconds. Default is 5.0.
 
 @discussion The cache holds an internal timer to check whether the cache reaches
 its limits, and if the limit is reached, it begins to evict objects.
 */
@property (assign) NSTimeInterval autoTrimInterval;

#pragma mark - Limit
///=============================================================================
/// @name Limit
///=============================================================================

/**
 The maximum number of objects the cache should hold.
 
 @discussion The default value is NSUIntegerMax, which means no limit.
 This is not a strict limit—if the cache goes over the limit, some objects in the
 cache could be evicted later in backgound thread.
 */
@property (assign) NSUInteger countLimit;

/**
 A block to be executed when the app receives a memory warning.
 The default value is nil.
 */
@property (copy) void(^didReceiveMemoryWarningBlock)(YYMemoryCache *cache);
/**
 If `YES`, the cache will remove all objects when the app receives a memory warning.
 The default value is `YES`.
 */
@property (assign) BOOL shouldRemoveAllObjectsOnMemoryWarning;

/**
 If `YES`, The cache will remove all objects when the app enter background.
 The default value is `YES`.
 */
@property (assign) BOOL shouldRemoveAllObjectsWhenEnteringBackground;

/**
 A block to be executed when the app enter background.
 The default value is nil.
 */
@property (copy) void(^didEnterBackgroundBlock)(YYMemoryCache *cache);
@end
