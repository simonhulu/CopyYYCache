//
//  YYMemoryCache.m
//  CopyYYCache
//
//  Created by szhang on 14/12/2015.
//  Copyright © 2015 szhang. All rights reserved.
//

#import "YYMemoryCache.h"
#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <libkern/OSAtomic.h>
#import <pthread.h>

#if __has_include("YYDispatchQueuePool.h")
#import "YYDispatchQueuePool.h"
#endif

#ifdef YYDispatchQueuePool_h
static inline dispatch_queue_t YYMemoryCacheGetReleaseQueue()
{
    return YYDispatchQueueGetForQOS(NSQualityOfServiceUtility);
}
#else
static inline dispatch_queue_t YYMemoryCacheGetReleaseQueue(){
    return dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW,0);
}
#endif

/**
 A node in linked map
 Typically, you should not use this class directly
 */
@interface _YYLinkedMapNode : NSObject{
    @package
    __unsafe_unretained _YYLinkedMapNode *_prev ;//retained by dic
    __unsafe_unretained _YYLinkedMapNode *_next ;//retained by dics
    id _key ;
    id _value ;
    NSUInteger _cost ;
    NSTimeInterval _time ;
}
@end

@implementation _YYLinkedMapNode
@end


/**
 A linked map used by YYMemoryCache.
 It's not thread-safe and does not validate the parameters.
 Thpically,you should not use this class directly.
 */
@interface _YYLinkedMap : NSObject{
    @package
    CFMutableDictionaryRef _dic ;//do not set object directly
    NSUInteger _totalCost ;
    NSUInteger _totalCount ;
    _YYLinkedMapNode *_head ;//MRU,do not change it directly
    _YYLinkedMapNode *_tail ;//LRU,do not change it directly
    BOOL _releaseOnMainThread ;
    BOOL _releaseAsynchronously ;
}

///Insert a node at head and update the total cost.
///Node and node.key should not be nil
-(void)insertNodeAtHead:(_YYLinkedMapNode *)node ;
///Bring a inner node to header.
///Node should already inside the dic
-(void)bringNodeToHead:(_YYLinkedMapNode *)node ;
///Remove a inner node and update the total cost.
-(void)removeNode:(_YYLinkedMapNode *)node ;
///Remove tail node if exist.
-(_YYLinkedMapNode *)removeTailNode ;
///Remove all node in background queue.
-(void)removeAll ;
@end

@implementation _YYLinkedMap

-(instancetype)init
{
    self = [super init] ;
    if (self) {
        _dic = CFDictionaryCreateMutable(CFAllocatorGetDefault(), 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks) ;
        _releaseOnMainThread = NO ;
        _releaseAsynchronously = YES ;
    }
    return self ;
}

-(void)dealloc
{
    CFRelease(_dic) ;
}

-(void)insertNodeAtHead:(_YYLinkedMapNode *)node{
    CFDictionarySetValue(_dic,(__bridge const void *)(node->_key), (__bridge const void *)(node));
    _totalCost += node->_cost ;
    _totalCost ++ ;
    if (_head) {
        node->_next = _head ;
        _head->_prev = node ;
        _head = node ;
    }else{
        _head = _tail = node ;
    }
}

-(void)bringNodeToHead:(_YYLinkedMapNode *)node
{
    if (_head == node)return ;
    
    if (_tail == node) {
        _tail = node->_prev ;
        _tail->_next = nil ;
    }else
    {
        node->_next->_prev = node->_prev ;
        node->_prev->_next = node->_next ;
    }
    node->_next = _head ;
    node->_prev = nil ;
    _head->_prev = node ;
    _head = node ;
}

-(void)removeNode:(_YYLinkedMapNode *)node
{
    CFDictionaryRemoveValue(_dic, (__bridge const void *)(node->_key)) ;
    _totalCost -= node->_cost ;
    _totalCost-- ;
    if (node->_next) {
        node->_next->_prev = node->_prev ;
    }
    if (node->_prev) {
        node->_prev->_next = node->_next ;
    }
    if (_head == node) {
        _head = node->_next ;
    }
    if (_tail == node) {
        _tail = node->_prev ;
    }
}

-(_YYLinkedMapNode *)removeTailNode{
    if (!_tail)return nil ;
    _YYLinkedMapNode *tail = _tail ;
    CFDictionaryRemoveValue(_dic, (__bridge const void *)(_tail->_key)) ;
    _totalCost -= _tail->_cost ;
    _totalCount-- ;
    if (_head == _tail) {
        _head = _tail = nil ;
    }else{
        _tail = _tail->_prev ;
        _tail->_next = nil ;
    }
    return tail ;
}

-(void)removeAll{
    _totalCost = 0 ;
    _totalCount = 0 ;
    _head = nil ;
    _tail = nil ;
    if (CFDictionaryGetCount(_dic) > 0) {
        CFMutableDictionaryRef holder = _dic ;
        _dic = CFDictionaryCreateMutable(CFAllocatorGetDefault(), 0,&kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        if (_releaseAsynchronously) {
            dispatch_queue_t queue = _releaseOnMainThread?dispatch_get_main_queue():YYMemoryCacheGetReleaseQueue();
            dispatch_async(queue, ^{
                CFRelease(holder) ;//hold and release in specified queue
            });
        }else if (_releaseOnMainThread && !pthread_main_np())
        {
            dispatch_async(dispatch_get_main_queue(), ^{
                CFRelease(holder) ; //hold and release in specified queue
            });
        }else
        {
            CFRelease(holder) ;
        }
    }
}



@end

@implementation YYMemoryCache{
    OSSpinLock _lock ;
    _YYLinkedMap *_lru ;
    dispatch_queue_t _queue ;
}

-(void)_trimToCost:(NSUInteger)costLimit{
    BOOL finish = NO ;
    OSSpinLockLock(&_lock) ;
    if (costLimit == 0) {
        [_lru removeAll] ;
        finish = YES ;
    }else if (_lru->_totalCost <= costLimit){
        finish = YES ;
    }
    OSSpinLockUnlock(&_lock);
    if (finish)return ;

    NSMutableArray *holder = [NSMutableArray new] ;
    while (!finish) {
        if (OSSpinLockTry(&_lock)) {
            if (_lru->_totalCost > costLimit) {
                _YYLinkedMapNode *node = [_lru removeTailNode] ;
                if (node)[holder addObject:node];

            }else{
                finish = YES ;
            }
            OSSpinLockUnlock(&_lock) ;
        }else{
            usleep(10*1000);//10 ms
        }
    }
    if (holder.count) {
        dispatch_queue_t queue = _lru->_releaseOnMainThread?dispatch_get_main_queue():YYMemoryCacheGetReleaseQueue() ;
        dispatch_async(queue, ^{
            [holder count] ;//release in queue
        });
    }
}

-(void)_trimToCount:(NSUInteger)countLimit{
    BOOL finish = NO ;
    OSSpinLockLock(&_lock);
    if (countLimit == 0) {
        [_lru removeAll];
        finish = YES ;
    }else if (_lru->_totalCount <= countLimit){
        finish = YES ;
    }
    OSSpinLockUnlock(&_lock) ;
    if (finish)return ;
    NSMutableArray *holder = [NSMutableArray new] ;
    while (!finish) {
        if (OSSpinLockTry(&_lock)) {
            if (_lru->_totalCount > countLimit) {
                _YYLinkedMapNode *node = [_lru removeTailNode] ;
                if (node)[holder addObject:node];
            }else{
                finish = YES ;
            }
            OSSpinLockUnlock(&_lock);
        }else{
            usleep(10*1000);//10 ms
        }
    }
    if (holder.count) {
        dispatch_queue_t queue = _lru->_releaseOnMainThread?dispatch_get_main_queue():YYMemoryCacheGetReleaseQueue();
        dispatch_async(queue, ^{
            [holder count] ;
        });
    }
}

-(void)_trimToAge:(NSTimeInterval)ageLimit{
    BOOL finish = NO ;
    NSTimeInterval now = CACurrentMediaTime() ;
    OSSpinLockLock(&_lock) ;
    if ( ageLimit <= 0) {
        [_lru removeAll];
        finish = YES ;
    }else if (!_lru->_tail || (now - _lru->_tail->_time) <= ageLimit)
    {
        finish = YES ;
    }
    OSSpinLockUnlock(&_lock);
    if (finish)return ;
    NSMutableArray *holder = [NSMutableArray new] ;
    while (!finish) {
        if (OSSpinLockTry(&_lock)) {
            if (_lru->_tail && (now - _lru->_tail->_time) > ageLimit) {
                _YYLinkedMapNode *node = [_lru removeTailNode] ;
                if (node)[holder addObject:node];
            }else{
                finish = YES ;
            }
            OSSpinLockUnlock(&_lock);
        }else{
            usleep(10 * 1000);//10 ms
        }
    }
    if (holder.count) {
        dispatch_queue_t queue = _lru->_releaseOnMainThread?dispatch_get_main_queue() : YYMemoryCacheGetReleaseQueue();
        dispatch_async(queue, ^{
            [holder count];// release in queue
        });
    }
}

-(void)_appDidReceiveMemoryWarningNotification{
    if (self.didReceiveMemoryWarningBlock) {
        self.didReceiveMemoryWarningBlock(self);
    }
    if (self.shouldRemoveAllObjectsOnMemoryWarning) {
        [self removeAllObjects];
    }
}

-(void)_appDidEnterBackgroundNotification{
    if (self.didEnterBackgroundBlock) {
        self.didEnterBackgroundBlock(self);
    }
    if (self.shouldRemoveAllObjectsWhenEnteringBackground) {
        [self removeAllObjects];
    }
}

#pragma mark - public
-(instancetype)init{
    self = super.init ;
    _lock = OS_SPINLOCK_INIT ;
    _lru = [_YYLinkedMap new] ;
    _queue = dispatch_queue_create(@"com.common.cache.memory", DISPATCH_QUEUE_SERIAL);
    
    _coun
}

-(void)removeAllObjects{
    OSSpinLockLock(&_lock);
    [_lru removeAll];
    OSSpinLockUnlock(&_lock);
}

@end
