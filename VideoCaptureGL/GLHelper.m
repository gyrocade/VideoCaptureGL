//
//  GLHelper.m


#import "GLHelper.h"
#import <CoreGraphics/CGGeometry.h>

@implementation GLHelper

+ (void)showError
{
    GLenum errorCode = glGetError();
    switch (errorCode) {
        case GL_INVALID_ENUM:
            printf("GL Error. Invalid Enum.\n");
            break;
        case GL_INVALID_VALUE:
            printf("GL Error. Invalid Value.\n");
            break;
        case GL_INVALID_OPERATION:
            printf("GL Error. Invalid Operation.\n");
            break;
        case GL_INVALID_FRAMEBUFFER_OPERATION:
            printf("GL Error. Invalid Framebuffer Operation.\n");
            break;
        case GL_OUT_OF_MEMORY:
            printf("GL Error. Out of Memory.\n");
            break;
        case GL_NO_ERROR:
            break;
    }
}

@end
