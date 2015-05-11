//
//  JSIInjector.h
//  Scripter
//
//  Created by Sash Zats on 4/27/15.
//  Copyright (c) 2015 Sash Zats. All rights reserved.
//

#import <Foundation/Foundation.h>


@class Protocol;

extern Protocol *JSIExportClass(Class cls);

extern BOOL JSIIsClassInjected(Class cls);
