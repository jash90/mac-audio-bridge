#include "opus_shim.h"

int mab_opus_encoder_set(OpusEncoder *encoder, int request, opus_int32 value) {
    return opus_encoder_ctl(encoder, request, value);
}

int mab_opus_encoder_get(OpusEncoder *encoder, int request, opus_int32 *value) {
    return opus_encoder_ctl(encoder, request, value);
}

int mab_opus_encoder_reset(OpusEncoder *encoder) {
    return opus_encoder_ctl(encoder, OPUS_RESET_STATE);
}

int mab_opus_decoder_get(OpusDecoder *decoder, int request, opus_int32 *value) {
    return opus_decoder_ctl(decoder, request, value);
}

int mab_opus_decoder_reset(OpusDecoder *decoder) {
    return opus_decoder_ctl(decoder, OPUS_RESET_STATE);
}
