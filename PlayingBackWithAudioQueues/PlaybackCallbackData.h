//
//  PlaybackCallbackData.h
//  PlayingBackWithAudioQueues
//
//  Created by Panayotis Matsinopoulos on 26/4/21.
//

#ifndef PlaybackCallbackData_h
#define PlaybackCallbackData_h

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>

typedef struct PlaybackCallbackData {
  AudioFileID                   playbackFile;
  SInt64                        packetPosition;
  UInt32                        numOfBytesToRead;
  UInt32                        numOfPacketsToRead;
  AudioStreamPacketDescription* packetDescs;
  Boolean                       isDone;
} PlaybackCallbackData;

#endif /* PlaybackCallbackData_h */
