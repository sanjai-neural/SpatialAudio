#import "CSystemAudioRing.h"

/*
 * Step 6b-1: the Objective-C half of the render path. Control thread only (it runs once, at setup). The block it creates runs on the
 * engine's render thread and makes EXACTLY ONE call, SARingRender, which lives in CSystemAudioRing.c under the Real-time rule.
 * scripts/scan-rt-block.sh checks the compiled invoke function (one allow-listed callee, called once) and then scans that callee
 * for zero calls. Not the macOS 27 initWithFormat:realtimeSafeRenderBlock:, and not callable from Swift.
 */
AVAudioSourceNode *SACreateSourceNode(SARingReader *reader, AVAudioFormat *format) {
    if (format.commonFormat != AVAudioPCMFormatFloat32 || format.channelCount != 1) return nil;
    return [[AVAudioSourceNode alloc] initWithFormat:format
                                         renderBlock:^OSStatus(BOOL *isSilence, const AudioTimeStamp *timestamp,
                                                               AVAudioFrameCount frameCount, AudioBufferList *outputData) {
        bool silent = false;
        const OSStatus status = SARingRender(reader, &silent, timestamp, frameCount, outputData);
        *isSilence = silent;
        return status;
    }];
}
