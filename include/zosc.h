#ifndef XOSC_H
#define XOSC_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct zosc_timetag_t {
  uint32_t seconds;
  uint32_t frac;
} zosc_timetag_t;

typedef struct zosc_bundle_iterator_t zosc_bundle_iterator_t;

// returns NULL on failure
zosc_bundle_iterator_t *zosc_bundle_iterator_create();

void zosc_bundle_iterator_destroy(zosc_bundle_iterator_t *self);

// returns false on failure
bool zosc_bundle_iterator_init(zosc_bundle_iterator_t *self, const char *ptr,
                               size_t len);

// returns NULL when the iterator is at the end
const char *zosc_bundle_iterator_next(zosc_bundle_iterator_t *self,
                                      size_t *len);

zosc_timetag_t
zosc_bundle_iterator_get_timetag(const zosc_bundle_iterator_t *self);

// resets the iterator to the beginning
void zosc_bundle_iterator_reset(zosc_bundle_iterator_t *self);

typedef struct zosc_bytes_t {
  const char *ptr;
  size_t len;
} zosc_bytes_t;

#ifdef __SIZEOF_INT128__
zosc_timetag_t zosc_timetag_from_nano_timestamp(__int128 nanoseconds);
#endif

zosc_timetag_t zosc_timetag_from_timestamp(int64_t seconds);

typedef union zosc_data_t {
  int i;
  float f;
  zosc_bytes_t s;
  zosc_bytes_t S;
  zosc_bytes_t b;
  zosc_timetag_t t;
  double d;
  char m[4];
  uint32_t r;
} zosc_data_t;

enum zosc_data_tag_t {
  ZOSC_DATA_i = 'i',
  ZOSC_DATA_f = 'f',
  ZOSC_DATA_s = 's',
  ZOSC_DATA_S = 'S',
  ZOSC_DATA_b = 'b',
  ZOSC_DATA_t = 't',
  ZOSC_DATA_d = 'd',
  ZOSC_DATA_m = 'm',
  ZOSC_DATA_r = 'r',
  ZOSC_DATA_T = 'T',
  ZOSC_DATA_I = 'I',
  ZOSC_DATA_F = 'F',
};

typedef struct zosc_message_iterator_t zosc_message_iterator_t;

// returns NULL on failure
zosc_message_iterator_t *zosc_message_iterator_create();

void zosc_message_iterator_destroy(zosc_message_iterator_t *self);

// returns false on failure
bool zosc_message_iterator_init(zosc_message_iterator_t *self, const char *ptr,
                                size_t len);

// returns -1 on error, 0 to signal the iterator is at the end and 1 otherwise
int zosc_message_iterator_next(zosc_message_iterator_t *self, zosc_data_t *data,
                               char *data_type);

// caller does not own this memory; do not free it
// returns NULL on failure
const char *zosc_message_iterator_get_path(const zosc_message_iterator_t *self,
                                           size_t *len);

// caller does not own this memory; do not free it
// returns NULL on failure
const char *zosc_message_iterator_get_types(const zosc_message_iterator_t *self,
                                            size_t *len);

void zosc_message_iterator_reset(zosc_message_iterator_t *self);

typedef struct zosc_message_t zosc_message_t;

// caller does not own this memory; do not free it
const char *zosc_message_get_path(const zosc_message_t *self, size_t *len);

// caller does not own this memory; do not free it
const char *zosc_message_get_types(const zosc_message_t *self, size_t *len);

// messages are reference-counted; this adds one to the reference count
void zosc_message_ref(zosc_message_t *self);

// messages are reference-counted; this subtracts one from the reference count
// messages are free'd once the count reaches zero
void zosc_message_unref(zosc_message_t *self);

// caller does not own this memory; do not free it
const char *zosc_message_to_bytes(zosc_message_t *self, size_t *len);

// returns NULL on failure
zosc_message_t *zosc_message_from_bytes(const char *ptr, size_t len);

// returns NULL on failure
zosc_message_t *zosc_message_clone(zosc_message_t *self);

// returns NULL on failure
zosc_message_t *zosc_message_build(const char *path_ptr, size_t path_len,
                                   const char *types_ptr, size_t types_len,
                                   const char *data_ptr, size_t data_len);

typedef struct zosc_message_builder_t zosc_message_builder_t;

// returns NULL on failure
zosc_message_builder_t *zosc_message_builder_create();

void zosc_message_builder_destroy(zosc_message_builder_t *self);

// returns NULL on failure
zosc_message_t *zosc_message_builder_commit(zosc_message_builder_t *self,
                                            const char *path_ptr, size_t len);

// returns false on failure
bool zosc_message_builder_append(zosc_message_builder_t *self, zosc_data_t data,
                                 char data_type);

typedef struct zosc_bundle_t zosc_bundle_t;

// returns { 0, 0 } on failure
zosc_timetag_t zosc_bundle_get_timetag(const zosc_bundle_t *self);

// bundles are reference-counted; this adds one to the reference count
void zosc_bundle_ref(zosc_bundle_t *self);

// bundles are reference-counted; this subtracts one from the reference count
// bundles are free'd once the count reaches zero
void zosc_bundle_unref(zosc_message_t *self);

// caller does not own this memory; do not free it
const char *zosc_bundle_to_bytes(zosc_bundle_t *self, size_t *len);

// returns NULL on failure
zosc_bundle_t *zosc_bundle_from_bytes(const char *ptr, size_t len);

// returns NULL on failure
zosc_bundle_t *zosc_bundle_build(zosc_timetag_t tag, const char *content_ptr,
                                 size_t content_len);

typedef struct zosc_bundle_builder_t zosc_bundle_builder_t;

// returns NULL on failure
zosc_bundle_builder_t *zosc_bundle_builder_create();

void zosc_bundle_builder_destroy(zosc_bundle_builder_t *self);

// returns NULL on failure
zosc_bundle_t *zosc_bundle_builder_commit(zosc_bundle_builder_t *self,
                                          zosc_timetag_t time);

// returns false on failure
bool zosc_bundle_builder_append(zosc_bundle_builder_t *self,
                                zosc_message_t *message);

bool zosc_match_path(const char *pattern_ptr, size_t pattern_len,
                     const char *path_ptr, size_t path_len);

bool zosc_match_types(const char *pattern_ptr, size_t pattern_len,
                      const char *types_ptr, size_t types_len);

#ifdef __cplusplus
}
#endif

#endif /* XOSC_H */
