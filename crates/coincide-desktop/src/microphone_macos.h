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
// -5 conversion, -6 device/configuration change, -7 invalid arguments.
void *cc_mic_start(size_t maximum_samples, int *error);
void cc_mic_stop(void *capture);
void cc_mic_cancel(void *capture);
int cc_mic_poll(void *capture);
size_t cc_mic_sample_count(void *capture);
int cc_mic_copy_samples(void *capture, float *destination, size_t capacity);
void cc_mic_destroy(void *capture);
// Fixture path uses AVAudioConverter only: never creates an engine or asks TCC.
int cc_mic_fixture_convert(const float *interleaved, size_t frames, uint32_t channels,
                          double rate, float *out, size_t capacity, size_t *written);
#endif
