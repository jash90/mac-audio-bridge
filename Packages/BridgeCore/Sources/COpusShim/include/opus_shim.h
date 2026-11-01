/* Non-variadic wrappers around the libopus ctl calls.
 *
 * opus_encoder_ctl / opus_decoder_ctl are variadic and the OPUS_SET_* /
 * OPUS_GET_* / OPUS_RESET_STATE names are function-like macros: neither is
 * callable from Swift. The integer *_REQUEST constants from opus_defines.h
 * import fine, so each wrapper takes one of them. All return OPUS_OK or a
 * negative OPUS_* error code. None of them allocates.
 */
#ifndef MAB_OPUS_SHIM_H
#define MAB_OPUS_SHIM_H

#include <opus.h>

/* Integer-valued encoder setter: `request` is an OPUS_SET_*_REQUEST
 * constant (bitrate, VBR, complexity, signal, bandwidth...). */
int mab_opus_encoder_set(OpusEncoder *encoder, int request, opus_int32 value);

/* Integer-valued encoder getter: `request` is an OPUS_GET_*_REQUEST constant
 * (bitrate, lookahead...). */
int mab_opus_encoder_get(OpusEncoder *encoder, int request, opus_int32 *value);

/* OPUS_RESET_STATE: back to the freshly created state, settings kept. */
int mab_opus_encoder_reset(OpusEncoder *encoder);

/* Integer-valued decoder getter (e.g. OPUS_GET_LAST_PACKET_DURATION_REQUEST). */
int mab_opus_decoder_get(OpusDecoder *decoder, int request, opus_int32 *value);

/* OPUS_RESET_STATE for a decoder: forgets the previous frames, so the next
 * packet is decoded as the start of a new stream. */
int mab_opus_decoder_reset(OpusDecoder *decoder);

#endif /* MAB_OPUS_SHIM_H */
