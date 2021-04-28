//
//  main.m
//  PlayingBackWithAudioQueues
//
//  Created by Panayotis Matsinopoulos on 26/4/21.
//

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import "NSPrint.h"
#import "CheckError.h"
#import "PlaybackCallbackData.h"
#import <sys/select.h>

#define kBufferDurationInSeconds 0.5
#define kNumberOfPlaybackBuffers 3

static void MyAQOutputCallback(void *inUserData,
                               AudioQueueRef inAQ,
                               AudioQueueBufferRef inCompleteAQBuffer) {
  PlaybackCallbackData *playbackCallbackData = (PlaybackCallbackData *)inUserData;
  if (playbackCallbackData->isDone) {
    return;
  }
  
  UInt32 numOfBytes = playbackCallbackData->numOfBytesToRead;
  UInt32 numOfPackets = playbackCallbackData->numPacketsToRead;
  CheckError(AudioFileReadPacketData(playbackCallbackData->playbackFile,
                                     false,
                                     &numOfBytes,
                                     playbackCallbackData->packetDescs,
                                     playbackCallbackData->packetPosition,
                                     &numOfPackets,
                                     inCompleteAQBuffer->mAudioData), "Reading packet data from audio file");
  if (numOfPackets > 0 && numOfBytes > 0) {
    inCompleteAQBuffer->mAudioDataByteSize = numOfBytes;
    CheckError(AudioQueueEnqueueBuffer(inAQ, inCompleteAQBuffer, numOfPackets, playbackCallbackData->packetDescs), "Audio enqueuing buffer");
    playbackCallbackData->packetPosition += numOfPackets;
  }
  else {
    CheckError(AudioQueueStop(inAQ, false), "Asynchronously stopping the queue");
    playbackCallbackData->isDone = true;
  }
}

void CalculateBytesForTime(AudioFileID audioFile, const AudioStreamBasicDescription* inAudioStreamBasicDescription, Float64 bufferDurationInSeconds, UInt32* oBufferByteSize, UInt32* oNumPacketsToRead) {
  UInt32 packetSizeUpperBound = 0;
  UInt32 packetSizeUpperBoundSize = sizeof(packetSizeUpperBound);
  
  // kAudioFilePropertyPacketSizeUpperBound
  // a UInt32 for the theoretical maximum packet size in the file (without actually scanning
  // the whole file to find the largest packet, as may happen with kAudioFilePropertyMaximumPacketSize).
  CheckError(AudioFileGetProperty(audioFile,
                                  kAudioFilePropertyPacketSizeUpperBound,
                                  &packetSizeUpperBoundSize,
                                  &packetSizeUpperBound), "Getting the packet size uppper bound from the audio file");
  const int maxBufferSize = 0x10000; // 64KB
  const int minBufferSize = 0x4000;  // 16KB
  if (inAudioStreamBasicDescription->mFramesPerPacket) {
    // VBR case
    Float64 totalNumberOfSamples = inAudioStreamBasicDescription->mSampleRate * bufferDurationInSeconds;
    UInt32 totalNumberOfFrames = ceil(totalNumberOfSamples); // 1 Frame for each 1 Sample, but round up
    UInt32 totalNumberOfPackets = totalNumberOfFrames / inAudioStreamBasicDescription->mFramesPerPacket;
    *oBufferByteSize = packetSizeUpperBound * totalNumberOfPackets;
  }
  else {
    // If frames (samples) per packet is zero, then the codec has no predictable packet size for given time
    // So we can't tailor this (we don't know how many Packets are represent in a time period
    // we'll just return a default buffer size
    *oBufferByteSize = maxBufferSize > packetSizeUpperBound ? maxBufferSize : packetSizeUpperBound;
  }
  
  if (*oBufferByteSize > maxBufferSize && *oBufferByteSize > packetSizeUpperBound) {
    // Let's not cross the limit if +maxBufferSize+
    *oBufferByteSize = maxBufferSize;
  }
  else {
    // but also, let's make sure we are not very small
    if (*oBufferByteSize < minBufferSize) {
      *oBufferByteSize = minBufferSize;
    }
  }
  *oNumPacketsToRead = *oBufferByteSize / packetSizeUpperBound;
}

static void AllocateMemoryForPacketDescriptionsArray(const AudioStreamBasicDescription *inAudioStreamBasicDescription, PlaybackCallbackData *ioPlaybackCallbackData) {
  Boolean isFormatVBR = inAudioStreamBasicDescription->mBytesPerPacket == 0 || inAudioStreamBasicDescription->mFramesPerPacket == 0;
  if (isFormatVBR) {
    // TODO: We will have to free this dynamically allocated buffer. no?
    ioPlaybackCallbackData->packetDescs = (AudioStreamPacketDescription*) malloc(sizeof(AudioStreamBasicDescription) * ioPlaybackCallbackData->numPacketsToRead);
  }
  else {
    ioPlaybackCallbackData->packetDescs = NULL;
  }
}

static void CopyEncoderMagicCookieToAudioQueue(const AudioFileID audioFile, AudioQueueRef queue) {
  UInt32 cookieDataSize = 0;
  UInt32 isWritable = 0;
  // This is the only case in the program that we should not use the CheckError utility function. Because,
  // the error != noErr indicates the absence of magic cookie rather than a run-time error that deserves the
  // program to stop.
  OSStatus error = AudioFileGetPropertyInfo(audioFile,
                                            kAudioFilePropertyMagicCookieData,
                                            &cookieDataSize, &isWritable);
  if (error == noErr && cookieDataSize > 0) {
    Byte* cookieData = (Byte *)malloc(cookieDataSize * sizeof(Byte));
    CheckError(AudioFileGetProperty(audioFile,
                                    kAudioFilePropertyMagicCookieData,
                                    &cookieDataSize,
                                    cookieData), "Getting the actual magic cookie data from the audio file");
    CheckError(AudioQueueSetProperty(queue, kAudioQueueProperty_MagicCookie, cookieData, cookieDataSize), "Setting the magic queue to the corresponding property in the Audio Queue");
    free(cookieData);
  }
}

int main(int argc, const char * argv[]) {
  @autoreleasepool {
    if (argc < 2) {
      NSLog(@"You need to give the input file for playing back. You can use any Core Audio supported file such as .mp3, .aac, .m4a, .wav, .aif e.t.c.");
      return 1;
    }
    
    NSPrint(@"Starting ...\n");
    
    // Get the file name in a URL
    NSString *audioFilePath = [[NSString stringWithUTF8String:argv[1]] stringByExpandingTildeInPath];
    NSURL *audioURL = [NSURL fileURLWithPath:audioFilePath];
    
    
    PlaybackCallbackData playbackCallbackData = {0};
    
    CheckError(AudioFileOpenURL((__bridge CFURLRef)audioURL,
                                kAudioFileReadPermission,
                                0,
                                &playbackCallbackData.playbackFile), "Opening the audio file");
    
    AudioStreamBasicDescription audioStreamBasicDescription;
    UInt32 audioStreamBasicDescriptionSize = sizeof(AudioStreamBasicDescription);
    CheckError(AudioFileGetProperty(playbackCallbackData.playbackFile,
                                    kAudioFilePropertyDataFormat,
                                    &audioStreamBasicDescriptionSize,
                                    &audioStreamBasicDescription), "Getting the audio stream basic description need from the audio file");
    
    AudioQueueRef queue;
    CheckError(AudioQueueNewOutput(&audioStreamBasicDescription,
                                   MyAQOutputCallback,
                                   &playbackCallbackData,
                                   NULL, NULL, 0,
                                   &queue), "Initializing the audio queue");
    
    CalculateBytesForTime(playbackCallbackData.playbackFile,
                          &audioStreamBasicDescription,
                          kBufferDurationInSeconds,
                          &playbackCallbackData.numOfBytesToRead,
                          &playbackCallbackData.numPacketsToRead);
    
    AllocateMemoryForPacketDescriptionsArray(&audioStreamBasicDescription, &playbackCallbackData);
    
    CopyEncoderMagicCookieToAudioQueue(playbackCallbackData.playbackFile, queue);
    
    // allocate audio queue buffers and fill them in with initial data using the callback function
    AudioQueueBufferRef buffers[kNumberOfPlaybackBuffers];
    playbackCallbackData.isDone = FALSE;
    playbackCallbackData.packetPosition = 0;
    for (int i = 0; i < kNumberOfPlaybackBuffers; i++) {
      CheckError(AudioQueueAllocateBuffer(queue, playbackCallbackData.numOfBytesToRead, &buffers[i]), "Allocating audio queue buffer");
      
      MyAQOutputCallback(&playbackCallbackData, queue, buffers[i]); // Note: The actual enqueueing of the buffer is done by the callback itself.
      if (playbackCallbackData.isDone) { // just in case the audio is less than 1.5 seconds (kNumberOfPlaybackBuffers * kBufferDurationInSeconds)
        break;
      }
    }
    
    NSPrint(@"Playing...Click <Enter> to terminate program\n");
    
    CheckError(AudioQueueStart(queue, NULL), "Audio queue start....the playback");
    
    getchar();
    
    // Clean up
    CheckError(AudioQueueStop(queue, TRUE), "Stopping Audio Queue...");
    CheckError(AudioQueueDispose(queue, TRUE), "Disposing Audio Queue...");
    if (playbackCallbackData.packetDescs) {
      free(playbackCallbackData.packetDescs);
    }
    CheckError(AudioFileClose(playbackCallbackData.playbackFile), "Closing audio file...");
    
    NSPrint(@"...bye!\n");
  }
  return 0;
}
