//
//  AVViewController.m
//  VideoCaptureGL
//

#import "AVViewController.h"
#import "GLHelper.h"
#import "ShaderProcessor.h"
#import <AVFoundation/AVFoundation.h>
#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/ES2/glext.h>

typedef struct TriVertex {
    GLKVector2 pos;
    GLKVector2 uv;
} TriVertex;

@interface AVViewController () <AVCaptureVideoDataOutputSampleBufferDelegate> {

    CVOpenGLESTextureRef _rgbaTexture;
    CVOpenGLESTextureCacheRef _videoTextureCache;
    dispatch_queue_t _sessionQueue;
    GLuint _program;
    GLuint _vertexArray;
    GLuint _vertexBuffer;
    CMSampleBufferRef _sampleBuffer;
}

@property (nonatomic, strong) EAGLContext *context;
@property (nonatomic, strong) AVCaptureSession *captureSession;
@property (nonatomic, strong) AVCaptureDevice *captureDevice;
@property (nonatomic, strong) AVCaptureVideoDataOutput *videoOutput;
@property (readwrite) GLint vertexAttrib;
@property (readwrite) GLint textureAttrib;
@property (readwrite) GLint videoFrameUniform;

@end

@implementation AVViewController

- (void)didReceiveMemoryWarning
{
    // Releases the view if it doesn't have a superview.
    [super didReceiveMemoryWarning];

    // Release any cached data, images, etc that aren't in use.
}

- (BOOL)prefersHomeIndicatorAutoHidden
{
    return YES;
}

- (void)viewDidLoad
{
    [super viewDidLoad];

    [UIApplication sharedApplication].idleTimerDisabled = YES;

    self.navigationController.navigationBarHidden = YES;
    CGFloat scale = [[UIScreen mainScreen] scale];

    self.context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
    if (!self.context)
    {
        NSLog(@"Failed to create ES context");
    }

    GLKView* view = (GLKView*)self.view;
    view.contentScaleFactor = scale;
    view.context = self.context;
    [EAGLContext setCurrentContext:self.context];

    [GLHelper showError];

    glDisable(GL_DITHER);
    glCullFace(GL_BACK);
    glFrontFace(GL_CCW);
    glDisable(GL_DEPTH_TEST);
    glDepthMask(GL_FALSE);
    glEnable(GL_BLEND);
    glClearColor(0.0, 0.0, 0.0, 1.0);

    [self loadShaders];
    [self setupBuffers];

    [self setupAV];
    [self.captureSession startRunning];
}

- (void)loadShaders
{
    _program = glCreateProgram();

    const char *vertexSource = "attribute vec4 position;\nattribute vec2 texCoord;\nvarying highp vec2 v_TexCoord;\nvoid main() {\nv_TexCoord = texCoord;\ngl_Position = position;}";

    const char *fragmentSource = "precision highp float;\nvarying vec2 v_TexCoord;\nuniform sampler2D u_VideoFrame;\nvoid main() {\ngl_FragColor = texture2D(u_VideoFrame, v_TexCoord);\n}";

    ShaderProcessor* shaderProcessor = [[ShaderProcessor alloc] init];
    _program = [shaderProcessor BuildProgram:vertexSource with:fragmentSource];

    self.vertexAttrib = glGetAttribLocation(_program, "position");
    self.textureAttrib = glGetAttribLocation(_program, "texCoord");

    self.videoFrameUniform = glGetUniformLocation(_program, "u_VideoFrame");
}

- (void)setupBuffers
{
    TriVertex vertexData[4];
    vertexData[0].pos = GLKVector2Make(-1.0f, -1.0f);
    vertexData[0].uv = GLKVector2Make(1.0f, 1.0f);
    vertexData[1].pos = GLKVector2Make(1.0f, -1.0f);
    vertexData[1].uv = GLKVector2Make(1.0f, 0.0f);
    vertexData[2].pos = GLKVector2Make(-1.0f, 1.0f);
    vertexData[2].uv = GLKVector2Make(0.0f, 1.0f);
    vertexData[3].pos = GLKVector2Make(1.0f, 1.0f);
    vertexData[3].uv = GLKVector2Make(0.0f, 0.0f);

    glGenVertexArraysOES(1, &_vertexArray);
    glBindVertexArrayOES(_vertexArray);

    glGenBuffers(1, &_vertexBuffer);
    glBindBuffer(GL_ARRAY_BUFFER, _vertexBuffer);
    glBufferData(GL_ARRAY_BUFFER, sizeof(vertexData), vertexData, GL_STATIC_DRAW);

    glEnableVertexAttribArray(self.vertexAttrib);
    glVertexAttribPointer(self.vertexAttrib, 2, GL_FLOAT, GL_FALSE, sizeof(TriVertex), (void*)offsetof(TriVertex, pos));

    glEnableVertexAttribArray(self.textureAttrib);
    glVertexAttribPointer(self.textureAttrib, 2, GL_FLOAT, GL_FALSE, sizeof(TriVertex), (void*)offsetof(TriVertex, uv));

    glBindVertexArrayOES(0);
}

- (void)dealloc
{
    if ([EAGLContext currentContext] == self.context) {
        [EAGLContext setCurrentContext:nil];
    }
    self.context = nil;
}

#pragma mark - GLKViewDelegate

- (void)glkView:(GLKView *)view drawInRect:(CGRect)rect
{
    glClear(GL_COLOR_BUFFER_BIT);

    if (!_videoTextureCache) {
        return;
    }

    glUseProgram(_program);
    glBindVertexArrayOES(_vertexArray);

    glActiveTexture(GL_TEXTURE0);
    glBindTexture(CVOpenGLESTextureGetTarget(_rgbaTexture), CVOpenGLESTextureGetName(_rgbaTexture));

    glUniform1i(self.videoFrameUniform, 0);

    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    glBindVertexArrayOES(0);
    glUseProgram(0);
}

- (void)setupAV
{
    _sessionQueue = dispatch_queue_create("cameraQueue", DISPATCH_QUEUE_SERIAL);

    CVReturn err = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, NULL, self.context, NULL, &_videoTextureCache);
    if (err) {
        NSLog(@"Couldn't create video cache.");
        return;
    }

    self.captureSession = [[AVCaptureSession alloc] init];
    if (!self.captureSession) {
        return;
    }

    [self.captureSession beginConfiguration];

    self.captureSession.sessionPreset = AVCaptureSessionPresetHigh;

    AVCaptureDevicePosition devicePosition = AVCaptureDevicePositionBack;

    AVCaptureDeviceDiscoverySession *deviceDiscoverySession = [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeBuiltInWideAngleCamera] mediaType:AVMediaTypeVideo position:devicePosition];

    for (AVCaptureDevice *device in deviceDiscoverySession.devices) {
        if (device.position == devicePosition) {
            self.captureDevice = device;
            if (self.captureDevice != nil) {
                break;
            }
        }
    }

    NSError *captureDeviceError = nil;
    AVCaptureDeviceInput *input = [[AVCaptureDeviceInput alloc] initWithDevice:self.captureDevice error:&captureDeviceError];
    if (captureDeviceError) {
        NSLog(@"Couldn't configure device input.");
        return;
    }

    if (![self.captureSession canAddInput:input]) {
        NSLog(@"Couldn't add video input.");
        [self.captureSession commitConfiguration];
        return;
    }

    [self.captureSession addInput:input];

    self.videoOutput = [[AVCaptureVideoDataOutput alloc] init];
    if (!self.videoOutput) {
        NSLog(@"Error creating video output.");
        [self.captureSession commitConfiguration];
        return;
    }

    self.videoOutput.alwaysDiscardsLateVideoFrames = YES;
    NSDictionary *settings = [[NSDictionary alloc] initWithObjectsAndKeys: [NSNumber numberWithInt:kCVPixelFormatType_32BGRA], kCVPixelBufferPixelFormatTypeKey, nil];
    self.videoOutput.videoSettings = settings;

    [self.videoOutput setSampleBufferDelegate:self queue:dispatch_get_main_queue()];

    if ([self.captureSession canAddOutput:self.videoOutput]) {
        [self.captureSession addOutput:self.videoOutput];
    } else {
        NSLog(@"Couldn't add video output.");
        [self.captureSession commitConfiguration];
        return;
    }

    if (self.captureSession.isRunning) {
        NSLog(@"Session is already running.");
        [self.captureSession commitConfiguration];
        return;
    }

    //            NSError *configLockError;
    //            int frameRate = 24;
    //            [self.captureDevice lockForConfiguration:&configLockError];
    //            self.captureDevice.activeVideoMinFrameDuration = CMTimeMake(1, frameRate);
    //            self.captureDevice.activeVideoMaxFrameDuration = CMTimeMake(1, frameRate);
    //            [self.captureDevice unlockForConfiguration];
    //
    //            if (configLockError) {
    //                NSLog(@"Error locking for configuration. %@", configLockError);
    //            }

    [self.captureSession commitConfiguration];
}

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection
{
    //    if (_sampleBuffer) {
    //        CFRelease(_sampleBuffer);
    //        _sampleBuffer = nil;
    //    }
    //
    //    OSStatus status = CMSampleBufferCreateCopy(kCFAllocatorDefault, sampleBuffer, &_sampleBuffer);
    //    if (noErr != status) {
    //        _sampleBuffer = nil;
    //    }
    //
    //    if (!_sampleBuffer) {
    //        return;
    //    }

    CVImageBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);

    if (!_videoTextureCache) {
        NSLog(@"No video texture cache");
        return;
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    size_t width = CVPixelBufferGetWidth(pixelBuffer);
    size_t height = CVPixelBufferGetHeight(pixelBuffer);

    _rgbaTexture = nil;
    // Periodic texture cache flush every frame
    CVOpenGLESTextureCacheFlush(_videoTextureCache, 0);

    // CVOpenGLESTextureCacheCreateTextureFromImage will create GLES texture
    // optimally from CVImageBufferRef.
    glActiveTexture(GL_TEXTURE0);
    CVReturn err = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                                _videoTextureCache,
                                                                pixelBuffer,
                                                                NULL,
                                                                GL_TEXTURE_2D,
                                                                GL_RGBA,
                                                                (GLsizei)width,
                                                                (GLsizei)height,
                                                                GL_BGRA,
                                                                GL_UNSIGNED_BYTE,
                                                                0,
                                                                &_rgbaTexture);

    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);

    if (err) {
        NSLog(@"Error at CVOpenGLESTextureCacheCreateTextureFromImage %d", err);
    }

    if (_rgbaTexture) {
        glBindTexture(CVOpenGLESTextureGetTarget(_rgbaTexture), CVOpenGLESTextureGetName(_rgbaTexture));
        glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    }
}

- (void)captureOutput:(AVCaptureOutput *)output didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection
{
    CMAttachmentMode mode;
    CFTypeRef reason = CMGetAttachment(sampleBuffer, kCMSampleBufferAttachmentKey_DroppedFrameReason, &mode);
    NSLog(@"Dropped frame: %@", reason);
}

@end
