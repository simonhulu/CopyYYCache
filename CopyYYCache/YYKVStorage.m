//
//  YYKVStorage.m
//  CopyYYCache
//
//  Created by szhang on 16/12/2015.
//  Copyright © 2015 szhang. All rights reserved.
//

#import "YYKVStorage.h"
#import <UIKit/UIKit.h>
#import <libkern/OSAtomic.h>
#import <time.h>

#if __has_include(<sqlite3.h>)
#import <sqlite3.h>
#else
#import "sqlite3.h"
#endif

static const int kPathLengthMax = PATH_MAX - 64 ;
static NSString *const kDBFileName = @"manifest.sqlite";
static NSString *const kDBShmFileName = @"manifest.sqlite-shm";
static NSString *const kDBWalFIleName = @"manifest.sqlite-wal";
static NSString *const kDataDirectoryName = @"data";
static NSString *const kTrashDirectoryName = @"trash";

/*
 SQL:
 create table if not exists manifest (
 key                 text,
 filename            text,
 size                integer,
 inline_data         blob,
 modification_time   integer,
 last_access_time    integer,
 extended_data       blob,
 primary key(key)
 );
 create index if not exists last_access_time_idx on manifest(last_access_time);
 */

@implementation YYKVStorageItem
@end

@implementation YYKVStorage{
    dispatch_queue_t _trashQueue ;
    
    NSString *_path ;
    NSString *_dbPath ;
    NSString *_dataPath ;
    NSString *_trashPath ;
    
    sqlite3 *_db ;
    CFMutableDictionaryRef _dbStmtCache ;
    
    BOOL _invalidated; ///< If YES, then the db should not open again, all read/write should be ignored.
    BOOL _dbIsClosing; ///< If YES, then the db is during closing.
    OSSpinLock _dbStateLock ;
}


#pragma mark - db

-(BOOL)_dbOpen{
    BOOL shouldOpen = YES ;
    OSSpinLockLock(&_dbStateLock);
    if (_invalidated) {
        shouldOpen = NO;
    }else if (_dbIsClosing){
        shouldOpen = NO ;
    }else if (_db)
    {
        shouldOpen = NO ;
    }
    OSSpinLockUnlock(&_dbStateLock);
    if (!shouldOpen) return YES ;
    
    int result = sqlite3_open(_dbPath.UTF8String, &_db);
    if (result == SQLITE_OK) {
        CFDictionaryKeyCallBacks keyCallbacks = kCFTypeDictionaryKeyCallBacks ;
        CFDictionaryValueCallBacks valueCallbacks = {0};
        _dbStmtCache = CFDictionaryCreateMutable(CFAllocatorGetDefault(), 0, &keyCallbacks, &valueCallbacks);
        return YES ;
    }else{
        NSLog(@"%s line:%d sqlite open failed (%d).", __FUNCTION__, __LINE__, result);
        return NO;
    }
}

-(BOOL)_dbClose{
    BOOL needClose = YES ;
    OSSpinLockLock(&_dbStateLock);
    if (!_db) {
        needClose = NO ;
    }else if (_invalidated){
        needClose = NO ;
    }else if (_dbIsClosing){
        needClose = NO ;
    }else{
        _dbIsClosing = YES ;
    }
    OSSpinLockLock(&_dbStateLock) ;
    if (!needClose)return YES ;
    
    int result = 0 ;
    BOOL retry = NO ;
    BOOL stmtFinalized = NO ;
    
    if (_dbStmtCache)CFRelease(_dbStmtCache);
    _dbStmtCache = NULL ;
    
    do{
        retry = NO ;
        result = sqlite3_close(_db) ;
        if (result == SQLITE_BUSY || result == SQLITE_LOCKED) {
            if (!stmtFinalized) {
                stmtFinalized = YES ;
                sqlite3_stmt *stmt ;
                while ((stmt = sqlite3_next_stmt(_db, nil))!=0) {
                    sqlite3_finalize(stmt);
                    retry = YES ;
                }
            }
        }else if (result != SQLITE_OK){
            NSLog(@"%s line:%d sqlite close failed (%d).",__FUNCTION__,__LINE__,result);
        }
    }while (retry);
    _db = NULL ;
    
    OSSpinLockLock(&_dbStateLock);
    _dbIsClosing = NO ;
    OSSpinLockUnlock(&_dbStateLock);
    
    return YES ;
}

-(BOOL)_dbIsReady{
    return (_db && !_dbIsClosing && !_invalidated);
}

-(BOOL)_dbInitialize{
    NSString *sql = @"pragma journal_mode = wal; pragma synchronous = normal; create table if not exists manifest (key text, filename text, size integer, inline_data blob, modification_time integer, last_access_time integer, extended_data blob, primary key(key)); create index if not exists last_access_time_idx on manifest(last_access_time);";
    return [self _dbExecute:sql];
}

-(BOOL)_dbExecute:(NSString *)sql{
    if (sql.length == 0) return NO ;
    if (![self _dbIsReady]) return NO ;
    
    char *error = NULL ;
    int result = sqlite3_exec(_db, sql.UTF8String, NULL, NULL, &error);
    if (error) {
        if (_errorLogsEnabled) NSLog(@"%s line:%d sqlite exec error (%d): %s", __FUNCTION__, __LINE__, result, error);
        sqlite3_free(error);
    }
    
    return result == SQLITE_OK ;
}

-(sqlite3_stmt *)_dbPrepareStmt:(NSString *)sql{
    if (![self _dbIsReady]) return NULL ;
    sqlite3_stmt *stmt = (sqlite3_stmt *)CFDictionaryGetValue(_dbStmtCache, (__bridge const void *)(sql));
    if (!stmt) {
        int result = sqlite3_prepare_v2(_db, sql.UTF8String, -1, &stmt, NULL);
        if (result != SQLITE_OK) {
            if (_errorLogsEnabled) NSLog(@"%s line:%d sqlite stmt prepare error (%d): %s",__FUNCTION__,__LINE__,result,sqlite3_errmsg(_db));
            return NULL ;
        }
        CFDictionarySetValue(_dbStmtCache, (__bridge const void *)(sql), stmt);
    }else{
        sqlite3_reset(stmt);
    }
    return stmt ;
}

-(NSString *)_dbJoinedKeys:(NSArray *)keys{
    NSMutableString *string = [NSMutableString new];
    for (NSUInteger i = 0, max = keys.count; i< max ;i++) {
        [string appendString:@"?"];
        if (i+1 != max) {
            [string appendString:@","];
        }
    }
    return string ;
}

-(void)_dbBindJoinedKeys:(NSArray *)keys stmt:(sqlite3_stmt *)stmt fromIndex:(int)index{
    for (int i = 0 ,max = (int)keys.count; i < max; i++) {
        NSString *key = keys[i];
        sqlite3_bind_text(stmt, index + i, key.UTF8String, -1, NULL);
    }
}

-(BOOL)_dbSaveWithKey:(NSString *)key value:(NSData *)value fileName:(NSString *)fileName extendedData:(NSData *)extendedData{
    NSString *sql = @"insert or replace into manifest (key, filename, size, inline_data, modification_time, last_access_time, extended_data) values (?1, ?2, ?3, ?4, ?5, ?6, ?7);";
    sqlite3_stmt *stmt = [self _dbPrepareStmt:sql];
    if (!stmt) return NO ;
    
    int timestamp = (int)time(NULL);
    sqlite3_bind_text(stmt, 1, key.UTF8String, -1, NULL);
    sqlite3_bind_text(stmt, 2, fileName.UTF8String, -1, NULL);
    sqlite3_bind_int(stmt, 3, (int)value.length);
    if (fileName.length == 0) {
        sqlite3_bind_blob(stmt, 4, value.bytes, (int)value, 0);
    }else{
        sqlite3_bind_blob(stmt, 4, NULL, 0, 0);
    }
    sqlite3_bind_int(stmt, 5, timestamp);
    sqlite3_bind_int(stmt, 6, timestamp);
    sqlite3_bind_blob(stmt, 7, extendedData.bytes, <#int n#>, <#void (*)(void *)#>)
}





























@end
