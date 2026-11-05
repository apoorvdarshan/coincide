#import <Foundation/Foundation.h>
#import <AVFAudio/AVFAudio.h>
#import <AVFoundation/AVFoundation.h>
#import <stdatomic.h>
#import <stdbool.h>
#import <math.h>
#import <unistd.h>
#import <time.h>
#import "microphone_macos.h"

#define CC_RATE 16000
#define CC_MAX_SAMPLES (CC_RATE * 600)
#define CC_SLOTS 8
static atomic_bool cc_capture_owned = false;

static BOOL CCReadyBundle(void) {
    NSBundle *bundle = NSBundle.mainBundle;
    id usage = [bundle objectForInfoDictionaryKey:@"NSMicrophoneUsageDescription"];
    return [bundle.bundleIdentifier isEqualToString:@"com.apoorvdarshan.coincide.rust"] && [usage isKindOfClass:NSString.class] && [usage length] > 0;
}
static double CCNow(void) { struct timespec value; clock_gettime(CLOCK_MONOTONIC, &value); return value.tv_sec + value.tv_nsec / 1e9; }
static int CCPermission(void) {
    if (!CCReadyBundle()) return 4;
    switch ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio]) {
        case AVAuthorizationStatusNotDetermined: return 0;
        case AVAuthorizationStatusAuthorized: return 1;
        case AVAuthorizationStatusDenied: return 2;
        case AVAuthorizationStatusRestricted: return 3;
    }
    return 4;
}
@interface CCPermissionRequest : NSObject { @public atomic_int result; }
@end
@implementation CCPermissionRequest
@end
int cc_mic_permission_status(void) { @autoreleasepool { return CCPermission(); } }
void *cc_mic_request_permission(void) {
    @autoreleasepool {
        CCPermissionRequest *request = [CCPermissionRequest new];
        atomic_init(&request->result, CCPermission());
        if (atomic_load(&request->result) == 0) {
            // The block retains the request even if Rust discards its handle.
            [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
                atomic_store_explicit(&request->result, granted ? 1 : 2, memory_order_release);
            }];
        }
        return (__bridge_retained void *)request;
    }
}
int cc_mic_permission_poll(void *request) {
    if (!request) return 4;
    CCPermissionRequest *object = (__bridge CCPermissionRequest *)request;
    return atomic_load_explicit(&object->result, memory_order_acquire);
}
void cc_mic_permission_destroy(void *request) {
    if (request) { @autoreleasepool { id released = CFBridgingRelease(request); (void)released; } }
}

// Runs only on the serial conversion queue or in the fixture. Never on the tap.
// Returns 0 success, 1 sample limit, or a negative conversion error.
static int CCConvert(AVAudioConverter *converter, AVAudioPCMBuffer *input, BOOL flush,
                     AVAudioPCMBuffer *output, float *samples, size_t maximum, size_t *count) {
    @try {
    __block BOOL supplied = NO;
    for (NSUInteger iteration = 0; iteration < 1024; iteration++) {
        output.frameLength = 0;
        NSError *error = nil;
        AVAudioConverterOutputStatus status = [converter convertToBuffer:output error:&error withInputFromBlock:^AVAudioBuffer *(AVAudioPacketCount wanted, AVAudioConverterInputStatus *inputStatus) {
            (void)wanted;
            if (input && !supplied) { supplied = YES; *inputStatus = AVAudioConverterInputStatus_HaveData; return input; }
            *inputStatus = flush ? AVAudioConverterInputStatus_EndOfStream : AVAudioConverterInputStatus_NoDataNow;
            return nil;
        }];
        if (error || status == AVAudioConverterOutputStatus_Error || !output.floatChannelData) return -5;
        size_t frames = output.frameLength;
        size_t available = maximum - *count;
        size_t copied = frames < available ? frames : available;
        const float *source = output.floatChannelData[0];
        for (size_t index = 0; index < copied; index++) {
            float sample = source[index];
            if (!isfinite(sample)) return -5;
            samples[(*count)++] = sample;
        }
        if (frames > copied || *count == maximum) return 1;
        if (status == AVAudioConverterOutputStatus_EndOfStream || status == AVAudioConverterOutputStatus_InputRanDry) return 0;
        if (!frames) return -5; // no-progress loop cannot hang stop/Drop
    }
    return -5;
    } @catch (NSException *exception) { (void)exception; return -5; }
}

@interface CCMicrophone : NSObject {
@public
    atomic_int state;
    atomic_int fault;
    atomic_bool accepting;
    atomic_uint callbacks;
    atomic_bool producing;
    atomic_size_t head;
    atomic_size_t tail;
    float *samples;
    size_t maximum;
    size_t sampleCount;
    AVAudioPCMBuffer *slots[CC_SLOTS];
    AVAudioFormat *inputFormat;
    AVAudioPCMBuffer *converted;
    AVAudioConverter *converter;
    AVAudioEngine *engine;
    dispatch_queue_t queue;
    dispatch_source_t timer;
    id configurationObserver;
    BOOL tapInstalled;
    BOOL ownsCapture;
    BOOL limited;
    double deadline;
}
- (void)consume;
- (void)finishCancelled:(BOOL)cancelled;
@end
@implementation CCMicrophone
- (void)consume {
    if (atomic_load_explicit(&state, memory_order_acquire) != 1) return;
    if (atomic_load(&fault)) { [self finishCancelled:YES]; return; }
    if (CCNow() >= deadline) { limited = YES; [self finishCancelled:NO]; return; }
    size_t first = atomic_load_explicit(&head, memory_order_relaxed);
    size_t last = atomic_load_explicit(&tail, memory_order_acquire);
    while (first != last) {
        int result = CCConvert(converter, slots[first % CC_SLOTS], NO, converted, samples, maximum, &sampleCount);
        atomic_store_explicit(&head, ++first, memory_order_release);
        if (result != 0) {
            if (result < 0) atomic_store(&fault, result);
            if (result == 1) limited = YES;
            [self finishCancelled:result < 0];
            return;
        }
    }
}
- (void)finishCancelled:(BOOL)cancelled {
    if (atomic_load_explicit(&state, memory_order_acquire) != 1) return;
    atomic_store_explicit(&accepting, false, memory_order_release);
    @try { if (tapInstalled) { [engine.inputNode removeTapOnBus:0]; tapInstalled = NO; } }
    @catch (NSException *exception) { (void)exception; atomic_store(&fault, -3); }
    @try { [engine stop]; }
    @catch (NSException *exception) { (void)exception; atomic_store(&fault, -3); }
    // Tap storage stays alive until every admitted invocation has returned.
    while (atomic_load_explicit(&callbacks, memory_order_acquire) != 0) usleep(1000);
    if (timer) { dispatch_source_cancel(timer); timer = nil; }
    if (configurationObserver) { [[NSNotificationCenter defaultCenter] removeObserver:configurationObserver]; configurationObserver = nil; }
    if (!cancelled && !atomic_load(&fault)) {
        size_t first = atomic_load(&head), last = atomic_load_explicit(&tail, memory_order_acquire);
        while (first != last && sampleCount < maximum) {
            int result = CCConvert(converter, slots[first++ % CC_SLOTS], NO, converted, samples, maximum, &sampleCount);
            if (result < 0) { atomic_store(&fault, result); break; }
            if (result == 1) break;
        }
        if (!atomic_load(&fault) && sampleCount < maximum) {
            int result = CCConvert(converter, nil, YES, converted, samples, maximum, &sampleCount);
            if (result < 0) atomic_store(&fault, result);
            if (result == 1) limited = YES;
        }
    }
    int error = atomic_load(&fault);
    if (cancelled || error) { sampleCount = 0; if (samples) memset(samples, 0, maximum * sizeof(float)); }
    if (ownsCapture) { atomic_store(&cc_capture_owned, false); ownsCapture = NO; }
    atomic_store_explicit(&state, error ? error : cancelled ? -1 : (limited || sampleCount == maximum) ? 3 : 2, memory_order_release);
}
- (void)dealloc {
    // All entrypoints destroy through finishCancelled on the serial queue.
    if (samples) memset(samples, 0, maximum * sizeof(float));
    free(samples);
}
@end

static void CCEnqueue(CCMicrophone *capture, AVAudioPCMBuffer *buffer) {
    size_t first = atomic_load_explicit(&capture->head, memory_order_acquire);
    size_t last = atomic_load_explicit(&capture->tail, memory_order_relaxed);
    if (last - first >= CC_SLOTS || ![buffer.format isEqual:capture->inputFormat]) { atomic_store(&capture->fault, -4); return; }
    AVAudioPCMBuffer *destination = capture->slots[last % CC_SLOTS];
    if (buffer.frameLength > destination.frameCapacity) { atomic_store(&capture->fault, -4); return; }
    destination.frameLength = buffer.frameLength;
    const AudioBufferList *source = buffer.audioBufferList;
    AudioBufferList *target = destination.mutableAudioBufferList;
    if (source->mNumberBuffers != target->mNumberBuffers) { atomic_store(&capture->fault, -3); return; }
    for (UInt32 index = 0; index < source->mNumberBuffers; index++) {
        if (source->mBuffers[index].mDataByteSize != target->mBuffers[index].mDataByteSize || !source->mBuffers[index].mData) { atomic_store(&capture->fault, -3); return; }
        memcpy(target->mBuffers[index].mData, source->mBuffers[index].mData, source->mBuffers[index].mDataByteSize);
    }
    atomic_store_explicit(&capture->tail, last + 1, memory_order_release);
}
static void CCTap(CCMicrophone *capture, AVAudioPCMBuffer *buffer) {
    atomic_fetch_add_explicit(&capture->callbacks, 1, memory_order_acq_rel);
    if (atomic_load_explicit(&capture->accepting, memory_order_acquire)) {
        bool expected = false;
        if (atomic_compare_exchange_strong(&capture->producing, &expected, true)) {
            CCEnqueue(capture, buffer);
            atomic_store_explicit(&capture->producing, false, memory_order_release);
        } else { atomic_store(&capture->fault, -4); }
    }
    atomic_fetch_sub_explicit(&capture->callbacks, 1, memory_order_release);
}

void *cc_mic_start(size_t maximum_samples, int *error) {
    @autoreleasepool {
        if (error) *error = -1;
        if (!maximum_samples || maximum_samples > CC_MAX_SAMPLES) { if (error) *error = -7; return NULL; }
        // Never request permission, or create an engine before authorization.
        if (CCPermission() != 1) { if (error) *error = -2; return NULL; }
        bool expected = false;
        if (!atomic_compare_exchange_strong(&cc_capture_owned, &expected, true)) return NULL;
        CCMicrophone *capture = [CCMicrophone new];
        if (!capture) { atomic_store(&cc_capture_owned, false); return NULL; }
        capture->ownsCapture = YES;
        atomic_init(&capture->state, 1); atomic_init(&capture->fault, 0);
        atomic_init(&capture->accepting, false); atomic_init(&capture->callbacks, 0);
        atomic_init(&capture->producing, false); atomic_init(&capture->head, 0); atomic_init(&capture->tail, 0);
        capture->queue = dispatch_queue_create("com.apoorvdarshan.coincide.rust.microphone", DISPATCH_QUEUE_SERIAL);
        capture->maximum = maximum_samples;
        capture->samples = calloc(maximum_samples, sizeof(float));
        @try {
            if (!capture->samples) @throw [NSException exceptionWithName:@"CaptureAllocation" reason:nil userInfo:nil];
            capture->engine = [AVAudioEngine new];
            AVAudioInputNode *input = capture->engine.inputNode;
            capture->inputFormat = [input outputFormatForBus:0];
            double rate = capture->inputFormat.sampleRate;
            if (!isfinite(rate) || rate < 8000 || rate > 192000 || !capture->inputFormat.channelCount || capture->inputFormat.channelCount > 8) @throw [NSException exceptionWithName:@"CaptureFormat" reason:nil userInfo:nil];
            AVAudioFormat *format = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:CC_RATE channels:1 interleaved:NO];
            capture->converter = [[AVAudioConverter alloc] initFromFormat:capture->inputFormat toFormat:format];
            capture->converter.downmix = YES;
            capture->converted = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:4096];
            if (!capture->converter || !capture->converted) @throw [NSException exceptionWithName:@"CaptureConverter" reason:nil userInfo:nil];
            AVAudioFrameCount capacity = (AVAudioFrameCount)ceil(rate * 0.5) + 64;
            for (int index = 0; index < CC_SLOTS; index++) {
                capture->slots[index] = [[AVAudioPCMBuffer alloc] initWithPCMFormat:capture->inputFormat frameCapacity:capacity];
                if (!capture->slots[index]) @throw [NSException exceptionWithName:@"CaptureSlot" reason:nil userInfo:nil];
            }
            __weak CCMicrophone *weakCapture = capture;
            AVAudioNodeTapBlock tap = ^(AVAudioPCMBuffer *buffer, AVAudioTime *time) { (void)time; CCMicrophone *strong = weakCapture; if (strong) CCTap(strong, buffer); };
            NSError *tapError = nil;
            if (@available(macOS 27.0, *)) {
                if (![input installTapOnBus:0 bufferSize:2048 format:capture->inputFormat error:&tapError block:tap]) @throw [NSException exceptionWithName:@"CaptureTap" reason:nil userInfo:nil];
            } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                [input installTapOnBus:0 bufferSize:2048 format:capture->inputFormat block:tap];
#pragma clang diagnostic pop
            }
            capture->tapInstalled = YES;
            capture->configurationObserver = [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioEngineConfigurationChangeNotification object:capture->engine queue:nil usingBlock:^(NSNotification *note) { (void)note; CCMicrophone *strong = weakCapture; if (strong && atomic_load_explicit(&strong->accepting, memory_order_acquire)) atomic_store(&strong->fault, -6); }];
            capture->deadline = CCNow() + (double)maximum_samples / CC_RATE;
            atomic_store_explicit(&capture->accepting, true, memory_order_release);
            NSError *startError = nil;
            if (![capture->engine startAndReturnError:&startError]) @throw [NSException exceptionWithName:@"CaptureStart" reason:nil userInfo:nil];
            capture->timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, capture->queue);
            dispatch_source_set_timer(capture->timer, dispatch_time(DISPATCH_TIME_NOW, 0), 5 * NSEC_PER_MSEC, NSEC_PER_MSEC);
            dispatch_source_set_event_handler(capture->timer, ^{ CCMicrophone *strong = weakCapture; if (strong) [strong consume]; });
            dispatch_resume(capture->timer);
            if (error) *error = 0;
            return (__bridge_retained void *)capture;
        } @catch (NSException *exception) {
            (void)exception;
            atomic_store(&capture->fault, -3);
            dispatch_sync(capture->queue, ^{ [capture finishCancelled:YES]; });
            if (error) *error = -3;
            return NULL;
        }
    }
}
void cc_mic_stop(void *handle) { if (handle) { CCMicrophone *capture = (__bridge CCMicrophone *)handle; dispatch_async(capture->queue, ^{ [capture finishCancelled:NO]; }); } }
void cc_mic_cancel(void *handle) { if (handle) { CCMicrophone *capture = (__bridge CCMicrophone *)handle; dispatch_sync(capture->queue, ^{ [capture finishCancelled:YES]; }); } }
int cc_mic_poll(void *handle) { return handle ? atomic_load_explicit(&((__bridge CCMicrophone *)handle)->state, memory_order_acquire) : -1; }
size_t cc_mic_sample_count(void *handle) { if (!handle || cc_mic_poll(handle) < 2) return 0; return ((__bridge CCMicrophone *)handle)->sampleCount; }
int cc_mic_copy_samples(void *handle, float *destination, size_t capacity) {
    if (!handle || !destination || cc_mic_poll(handle) < 2) return -1;
    CCMicrophone *capture = (__bridge CCMicrophone *)handle;
    if (capacity < capture->sampleCount) return -7;
    memcpy(destination, capture->samples, capture->sampleCount * sizeof(float)); return 0;
}
void cc_mic_destroy(void *handle) {
    if (!handle) return;
    @autoreleasepool { CCMicrophone *capture = CFBridgingRelease(handle); dispatch_sync(capture->queue, ^{ [capture finishCancelled:YES]; }); }
}
int cc_mic_fixture_convert(const float *interleaved, size_t frames, uint32_t channels, double rate, float *out, size_t capacity, size_t *written) {
    @autoreleasepool {
        if (!interleaved || !out || !written || !frames || frames > 192000 || !channels || channels > 8 || !isfinite(rate) || rate < 8000 || rate > 192000 || !capacity || capacity > CC_MAX_SAMPLES) return -7;
        *written = 0;
        @try {
            AVAudioFormat *source = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:rate channels:channels interleaved:YES];
            AVAudioFormat *target = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:CC_RATE channels:1 interleaved:NO];
            AVAudioPCMBuffer *input = [[AVAudioPCMBuffer alloc] initWithPCMFormat:source frameCapacity:(AVAudioFrameCount)frames];
            AVAudioPCMBuffer *output = [[AVAudioPCMBuffer alloc] initWithPCMFormat:target frameCapacity:4096];
            AVAudioConverter *converter = [[AVAudioConverter alloc] initFromFormat:source toFormat:target];
            if (!input || !output || !converter) return -5;
            converter.downmix = YES; input.frameLength = (AVAudioFrameCount)frames;
            memcpy(input.floatChannelData[0], interleaved, frames * channels * sizeof(float));
            int result = CCConvert(converter, input, NO, output, out, capacity, written);
            if (result) return result;
            return CCConvert(converter, nil, YES, output, out, capacity, written);
        } @catch (NSException *exception) { (void)exception; return -5; }
    }
}
