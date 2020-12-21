//
//  CTMediator.m
//  CTMediator
//
//  Created by casa on 16/3/13.
//  Copyright © 2016年 casa. All rights reserved.
//

#import "CTMediator.h"
#import <objc/runtime.h>
#import <CoreGraphics/CoreGraphics.h>

NSString * const kCTMediatorParamsKeySwiftTargetModuleName = @"kCTMediatorParamsKeySwiftTargetModuleName";

@interface CTMediator ()

@property (nonatomic, strong) NSMutableDictionary *cachedTarget;

@end

@implementation CTMediator

#pragma mark - public methods
+ (instancetype)sharedInstance
{
    static CTMediator *mediator;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        mediator = [[CTMediator alloc] init];
        // 同时把cachedTarget初始化，避免多线程重复初始化
        [mediator cachedTarget];
    });
    return mediator;
}

/*
 scheme://[target]/[action]?[params]
 
 url sample:
 aaa://targetA/actionB?id=1234
 */

- (id)performActionWithUrl:(NSURL *)url completion:(void (^)(NSDictionary *))completion
{
    if (url == nil) {
        return nil;
    }
    
    // 初始化参数字典
    NSMutableDictionary *params = [[NSMutableDictionary alloc] init];
    NSString *urlString = [url query];
    // 处理URL中的参数
    for (NSString *param in [urlString componentsSeparatedByString:@"&"]) {
        NSArray *elts = [param componentsSeparatedByString:@"="];
        if([elts count] < 2) continue;
        [params setObject:[elts lastObject] forKey:[elts firstObject]];
    }
    
    // 这里这么写主要是出于安全考虑，防止黑客通过远程方式调用本地模块。这里的做法足以应对绝大多数场景，如果要求更加严苛，也可以做更加复杂的安全逻辑。
    // 目标方法
    NSString *actionName = [url.path stringByReplacingOccurrencesOfString:@"/" withString:@""];
    if ([actionName hasPrefix:@"native"]) {
        return @(NO);
    }
    
    // 这个demo针对URL的路由处理非常简单，就只是取对应的target名字和method名字，但这已经足以应对绝大部份需求。如果需要拓展，可以在这个方法调用之前加入完整的路由逻辑
    // 调用本地组件调用入口
    id result = [self performTarget:url.host action:actionName params:params shouldCacheTarget:NO];
    if (completion) {
        if (result) {
            completion(@{@"result":result});
        } else {
            completion(nil);
        }
    }
    return result;
}

// 本地组件调用入口
- (id)performTarget:(NSString *)targetName action:(NSString *)actionName params:(NSDictionary *)params shouldCacheTarget:(BOOL)shouldCacheTarget
{
    if (targetName == nil || actionName == nil) {
        return nil;
    }
    
    // swift组件名称
    NSString *swiftModuleName = params[kCTMediatorParamsKeySwiftTargetModuleName];
    
    // generate target 目标类
    NSString *targetClassString = nil;
    if (swiftModuleName.length > 0) {
        // swift组件目标类字符串
        targetClassString = [NSString stringWithFormat:@"%@.Target_%@", swiftModuleName, targetName];
    } else {
        // OC目标类字符串
        targetClassString = [NSString stringWithFormat:@"Target_%@", targetName];
    }
    // 目标对象
    NSObject *target = [self safeFetchCachedTarget:targetClassString];
    // 目标对象为nil
    if (target == nil) {
        // 根据字符串，获取目标类
        Class targetClass = NSClassFromString(targetClassString);
        // 创建目标类对象
        target = [[targetClass alloc] init];
    }

    // generate action 目标方法字符串
    NSString *actionString = [NSString stringWithFormat:@"Action_%@:", actionName];
    // 目标方法
    SEL action = NSSelectorFromString(actionString);
    
    if (target == nil) {
        // 这里是处理无响应请求的地方之一，这个demo做得比较简单，如果没有可以响应的target，就直接return了。实际开发过程中是可以事先给一个固定的target专门用于在这个时候顶上，然后处理这种请求的
        [self NoTargetActionResponseWithTargetString:targetClassString selectorString:actionString originParams:params];
        return nil;
    }
    
    // 是否缓存目标对象
    if (shouldCacheTarget) {
        // 缓存目标对象
        [self safeSetCachedTarget:target key:targetClassString];
    }

    // target能否响应action
    if ([target respondsToSelector:action]) {
        // 安全执行target的action
        return [self safePerformAction:action target:target params:params];
    } else {
        // 这里是处理无响应请求的地方，如果无响应，则尝试调用对应target的notFound方法统一处理
        // notFound方法
        SEL action = NSSelectorFromString(@"notFound:");
        // target能否响应notFound方法
        if ([target respondsToSelector:action]) {
            // 安全执行target的notFound方法
            return [self safePerformAction:action target:target params:params];
        } else {
            // 这里也是处理无响应请求的地方，在notFound都没有的时候，这个demo是直接return了。实际开发过程中，可以用前面提到的固定的target顶上的。
            [self NoTargetActionResponseWithTargetString:targetClassString selectorString:actionString originParams:params];
            @synchronized (self) {
                // 移除缓存目标对象
                [self.cachedTarget removeObjectForKey:targetClassString];
            }
            return nil;
        }
    }
}

// 释放缓存目标对象
- (void)releaseCachedTargetWithFullTargetName:(NSString *)fullTargetName
{
    /*
     fullTargetName在oc环境下，就是Target_XXXX。要带上Target_前缀。在swift环境下，就是XXXModule.Target_YYY。不光要带上Target_前缀，还要带上模块名。
     */
    if (fullTargetName == nil) {
        return;
    }
    @synchronized (self) {
        [self.cachedTarget removeObjectForKey:fullTargetName];
    }
}

#pragma mark - private methods
// 没有目标对象来执行响应
- (void)NoTargetActionResponseWithTargetString:(NSString *)targetString selectorString:(NSString *)selectorString originParams:(NSDictionary *)originParams
{
    // 默认响应方法
    SEL action = NSSelectorFromString(@"Action_response:");
    // 默认无目标对象响应时的目标对象
    NSObject *target = [[NSClassFromString(@"Target_NoTargetAction") alloc] init];
    
    // 参数
    NSMutableDictionary *params = [[NSMutableDictionary alloc] init];
    // 源参数
    params[@"originParams"] = originParams;
    // 源目标对象字符串
    params[@"targetString"] = targetString;
    // 源响应方法字符串
    params[@"selectorString"] = selectorString;
    
    // 执行安全响应方法
    [self safePerformAction:action target:target params:params];
}

- (id)safePerformAction:(SEL)action target:(NSObject *)target params:(NSDictionary *)params
{
    // 获取方法签名
    NSMethodSignature* methodSig = [target methodSignatureForSelector:action];
    if(methodSig == nil) {
        return nil;
    }
    
    // 返回值类行
    const char* retType = [methodSig methodReturnType];

    // strcmp:字符串比较，相等返回0
    // 返回值是void类行
    if (strcmp(retType, @encode(void)) == 0) {
        // 方法调用对象
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:methodSig];
        // 设置参数
        [invocation setArgument:&params atIndex:2];
        // 调用的方法
        [invocation setSelector:action];
        // 设置调用者
        [invocation setTarget:target];
        // 进行调用
        [invocation invoke];
        return nil;
    }

    // 返回值是NSInteger类行
    if (strcmp(retType, @encode(NSInteger)) == 0) {
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:methodSig];
        [invocation setArgument:&params atIndex:2];
        [invocation setSelector:action];
        [invocation setTarget:target];
        [invocation invoke];
        // 返回默认值
        NSInteger result = 0;
        // 获取返回值
        [invocation getReturnValue:&result];
        // 返回
        return @(result);
    }

    // 返回值是BOOL类行
    if (strcmp(retType, @encode(BOOL)) == 0) {
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:methodSig];
        [invocation setArgument:&params atIndex:2];
        [invocation setSelector:action];
        [invocation setTarget:target];
        [invocation invoke];
        BOOL result = 0;
        [invocation getReturnValue:&result];
        return @(result);
    }

    // 返回值是CGFloat类行
    if (strcmp(retType, @encode(CGFloat)) == 0) {
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:methodSig];
        [invocation setArgument:&params atIndex:2];
        [invocation setSelector:action];
        [invocation setTarget:target];
        [invocation invoke];
        CGFloat result = 0;
        [invocation getReturnValue:&result];
        return @(result);
    }

    // 返回值是NSUInteger类行
    if (strcmp(retType, @encode(NSUInteger)) == 0) {
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:methodSig];
        [invocation setArgument:&params atIndex:2];
        [invocation setSelector:action];
        [invocation setTarget:target];
        [invocation invoke];
        NSUInteger result = 0;
        [invocation getReturnValue:&result];
        return @(result);
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    // 返回对象类型
    return [target performSelector:action withObject:params];
#pragma clang diagnostic pop
}

#pragma mark - getters and setters
- (NSMutableDictionary *)cachedTarget
{
    if (_cachedTarget == nil) {
        _cachedTarget = [[NSMutableDictionary alloc] init];
    }
    return _cachedTarget;
}

// 安全获取目标对象
- (NSObject *)safeFetchCachedTarget:(NSString *)key {
    // 加锁
    @synchronized (self) {
        // 从缓存目标字典获取目标对象
        return self.cachedTarget[key];
    }
}

// 安全缓存目标对象
- (void)safeSetCachedTarget:(NSObject *)target key:(NSString *)key {
    // 加锁
    @synchronized (self) {
        // 缓存目标对象到缓存目标字典
        self.cachedTarget[key] = target;
    }
}


@end

CTMediator* _Nonnull CT(void){
    return [CTMediator sharedInstance];
};
