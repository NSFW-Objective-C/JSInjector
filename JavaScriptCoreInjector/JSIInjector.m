//
//  JSIInjector.m
//  Scripter
//
//  Created by Sash Zats on 4/27/15.
//  Copyright (c) 2015 Sash Zats. All rights reserved.
//

#import "JSIInjector.h"

#import <JavaScriptCore/JavaScriptCore.h>
#import <objc/runtime.h>


//#define INJ_DEBUG_LOG


// These guys are from objc-runtime

typedef struct inj_method_t {
    SEL name;
    const char *types;
    IMP imp;
} inj_method_t;

typedef struct inj_method_list_t {
    uint32_t entsize_NEVER_USE;
    uint32_t count;
    inj_method_t first;
} inj_method_list_t;

typedef struct inj_property_t {
    const char *name;
    const char *attributes;
} inj_property_t;

typedef struct inj_property_list_t {
    uint32_t entsize;
    uint32_t count;
    inj_property_t first;
} inj_property_list_t;

typedef uintptr_t inj_protocol_ref_t;

typedef struct inj_protocol_list_t {
    // count is 64-bit by accident.
    uintptr_t count;
    inj_protocol_ref_t list[0]; // variable-size
} inj_protocol_list_t;

typedef struct inj_my_protocol {
    Class isa;
    const char *mangledName;
    inj_protocol_list_t *protocols;
    inj_method_list_t *instanceMethods;
    inj_method_list_t *classMethods;
    inj_method_list_t *optionalInstanceMethods;
    inj_method_list_t *optionalClassMethods;
    inj_property_list_t *instanceProperties;
    uint32_t size;   // sizeof(protocol_t)
    uint32_t flags;
    const char **extendedMethodTypes;
    const char *_demangledName;
}  inj_protocol_t;


static BOOL JSIIsBlacklistedClass(Class cls) {
    static NSSet *blacklist;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        blacklist = [NSSet setWithObjects:
            @"_NSZombie_", @"NSDecimalNumber", @"NSMethodSignature",
            @"CAAnimation", @"CADisplayLink", @"CAEAGLLayer", @"CAEmitterLayer", @"CAGradientLayer"
        , nil];
    });
    const char *cClassName = class_getName(cls);
    NSString *className = [NSString stringWithUTF8String:cClassName];
    return [blacklist containsObject:className];
}

static NSString *const JSIProtocolNameForClass(Class cls) {
    return [NSString stringWithFormat:@"%@_JSExport", NSStringFromClass(cls)];
}

static Protocol *JSIProtocolForClass(Class cls) {
    return NSProtocolFromString(JSIProtocolNameForClass(cls));
}

BOOL JSIIsClassInjected(Class cls) {
    return JSIProtocolForClass(cls) != nil;
}

/**
 *  According to objc runtime's getExtendedTypesIndexesForMethod, following is the order of extendedTypes:
 *
 *  1. required instance methods
 *  2. required class methods
 *  3. optional instance methods
 *  4. optional class methods
 *
 *  Since we're creating list of required methods only:
 *
 *  1. instance methods
 *  2. class methods
 */
Protocol *JSIExportClass(Class cls) {
    if (JSIIsBlacklistedClass(cls)) {
        return nil;
    }
    
    if (JSIIsClassInjected(cls)) {
        // runtime is the cache here
        return JSIProtocolForClass(cls);
    }
    
    Class superclass = class_getSuperclass(cls);
    if (superclass && !JSIIsClassInjected(superclass)) {
        // before we continue, making sure all superclasses are already JSExport-complient
        JSIExportClass(superclass);
    }
    
#ifdef INJ_DEBUG_LOG
    NSMutableString *log = [NSMutableString stringWithString:INJJSExportProtocolNameForClass(cls)];
#endif
    
    // Creating protocol
    Protocol *protocol = objc_allocateProtocol(JSIProtocolNameForClass(cls).UTF8String);

    // Protocol hierarchy
    protocol_addProtocol(protocol, @protocol(JSExport));
    protocol_addProtocol(protocol, @protocol(NSObject));

    if (cls != [NSObject class] && superclass != [NSObject class]) {
        protocol_addProtocol(protocol, JSIProtocolForClass(superclass));
#ifdef INJ_DEBUG_LOG
        [log appendFormat:@"\nSuperprotocol: %@", INJJSExportProtocolNameForClass(superclass)];
#endif
    }
    
    // Properties
    {
        unsigned int propertiesCount;
#ifdef INJ_DEBUG_LOG
        [log appendString:@"\nProperties"];
#endif
        objc_property_t *propertyList = class_copyPropertyList(cls, &propertiesCount);
        for (unsigned int i = 0; i < propertiesCount; ++i) {
            objc_property_t property = propertyList[i];
#ifdef INJ_DEBUG_LOG
            [log appendFormat:@"\n\t%s %s", property_getName(property), property_getAttributes(property)];
#endif
            unsigned int attributesCount;
            objc_property_attribute_t *attributeList = property_copyAttributeList(property, &attributesCount);
            protocol_addProperty(protocol, property_getName(property), attributeList, attributesCount, YES, YES);
            free(attributeList);
        }
        free(propertyList);
    }
    
    NSMutableArray *signatures = [NSMutableArray array];
    // Instance methods
     {
        unsigned int instanceMethodCount;
        Method *instanceMethods = class_copyMethodList(cls, &instanceMethodCount);
        if (instanceMethods) {
#ifdef INJ_DEBUG_LOG
            [log appendString:@"\nInstance methods"];
#endif
            for (unsigned int i = 0; i < instanceMethodCount; ++i) {
                Method method = instanceMethods[i];
                struct objc_method_description *description = method_getDescription(method);
                if (description && description->name && description->types) {
                    NSString *methodType = @(description->types);
                    if ([methodType containsString:@"?"]) {
#ifdef INJ_DEBUG_LOG
                        [log appendFormat:@"\nWARNING: Skipping method -[%@ %@], signature includes an unknown type \"%@\"", NSStringFromClass(cls), NSStringFromSelector(description->name), @(description->types)];
#endif
                        continue;
                    }
#ifdef INJ_DEBUG_LOG
                    [log appendFormat:@"\n\t%@ %s", NSStringFromSelector(method_getName(method)), description->types];
#endif
                    protocol_addMethodDescription(protocol, description->name, description->types, YES, YES);
                    [signatures addObject:@(description->types)];
                }
            }
            free(instanceMethods);
        }
    }
    
    // Class methods
    {
        unsigned int classMethodCount;
        Method *classMethods = class_copyMethodList(object_getClass(cls), &classMethodCount);
        if (classMethods) {
#ifdef INJ_DEBUG_LOG
            [log appendString:@"\nClass methods"];
#endif
            for (unsigned int i = 0; i < classMethodCount; ++i) {
                Method method = classMethods[i];
                if (method) {
                    struct objc_method_description *description = method_getDescription(method);
                    if (description && description->name && description->types) {
#ifdef INJ_DEBUG_LOG
                        [log appendFormat:@"\n\t%@ %s", NSStringFromSelector(method_getName(method)), description->types];
#endif
                        protocol_addMethodDescription(protocol, description->name, description->types, YES, NO);
                        [signatures addObject:@(description->types)];
                    }
                }
            }
            free(classMethods);
        }
    }
    
    objc_registerProtocol(protocol);

    // adding protocol_t->extendedMethodTypes manually
    inj_protocol_t *injProtocol = (__bridge inj_protocol_t *)protocol;
    injProtocol->extendedMethodTypes = malloc(sizeof(char *) * signatures.count);
    for (NSUInteger i = 0; i < signatures.count; ++i) {
        const char *src = ((NSString *)signatures[i]).UTF8String;
        char *dst = malloc(sizeof(char) * strlen(src) + 1);
        strcpy(dst, src);
        injProtocol->extendedMethodTypes[i] = dst;
    }
    NSCAssert(class_addProtocol(cls, protocol), @"Failed to add protocol");
#ifdef INJ_DEBUG_LOG
    NSLog(@"\n\n%@", log);
#endif
    
    
    return protocol;
}
