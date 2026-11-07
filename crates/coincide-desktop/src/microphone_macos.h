#ifndef COINCIDE_MICROPHONE_H
#define COINCIDE_MICROPHONE_H
#include <stddef.h>
#include <stdint.h>
// Permission: 0 undetermined/pending, 1 authorized, 2 denied, 3 restricted, 4 unavailable.
int cc_mic_permission_status(void);
void *cc_mic_request_permission(void);
int cc_mic_permission_poll(void *request);
void cc_mic_permission_destroy(void *request);
// Capture state: 1 recording, 2 ready, 3 limit reached, negative = failure.
// Error codes: -1 unavailable, -2 permission, -3 input/format, -4 overflow,
// -5 conversion, -6 device/configuration change, -7 invalid arguments, -8 busy (another owner).
typedef struct { char *uid; char *name; int is_default; } CCMicInputDevice;
int cc_mic_input_devices(CCMicInputDevice **out, size_t *count);
void cc_mic_input_devices_free(CCMicInputDevice *devices, size_t count);
uint32_t cc_mic_resolve_input_device(const char *uid);
void *cc_mic_start(size_t maximum_samples, int *error);
void *cc_mic_start_device(size_t maximum_samples, const char *uid, int *error);
void cc_mic_stop(void *capture);
void cc_mic_cancel(void *capture);
int cc_mic_poll(void *capture);
// Read-only atomics from already-converted audio, never a permission/device call.
int cc_mic_progress(void *capture, size_t *samples, float *level);
// Copies at most4096 already-published converted samples on the conversion queue.
int cc_mic_read_samples(void *capture, size_t offset, float *out, size_t capacity, size_t *written);
size_t cc_mic_sample_count(void *capture);
int cc_mic_copy_samples(void *capture, float *destination, size_t capacity);
void cc_mic_destroy(void *capture);
// Fixture path uses AVAudioConverter only: never creates an engine or asks TCC.
int cc_mic_fixture_read_published(void);
int cc_mic_fixture_convert(const float *interleaved, size_t frames, uint32_t channels,
                          double rate, float *out, size_t capacity, size_t *written);
#endif
