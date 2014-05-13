/*
 Copyright © Roman Zechmeister, 2014
 
 Diese Datei ist Teil von Libmacgpg.
 
 Libmacgpg ist freie Software. Sie können es unter den Bedingungen 
 der GNU General Public License, wie von der Free Software Foundation 
 veröffentlicht, weitergeben und/oder modifizieren, entweder gemäß 
 Version 3 der Lizenz oder (nach Ihrer Option) jeder späteren Version.
 
 Die Veröffentlichung von Libmacgpg erfolgt in der Hoffnung, daß es Ihnen 
 von Nutzen sein wird, aber ohne irgendeine Garantie, sogar ohne die implizite 
 Garantie der Marktreife oder der Verwendbarkeit für einen bestimmten Zweck. 
 Details finden Sie in der GNU General Public License.
 
 Sie sollten ein Exemplar der GNU General Public License zusammen mit diesem 
 Programm erhalten haben. Falls nicht, siehe <http://www.gnu.org/licenses/>.
 */

#import "GPGPacket.h"
#import "GPGMemoryStream.h"
#import "GPGGlobals.h"
#import "GPGException.h"
#include <string.h>
#include <openssl/bio.h>
#include <openssl/evp.h>

#define COMMON_DIGEST_FOR_OPENSSL
#include <CommonCrypto/CommonDigest.h>


#define readUint8 (*((*((uint8_t**)&readPos))++))
#define readUint16 CFSwapInt16BigToHost(*((*((uint16_t**)&readPos))++))
#define readUint32 CFSwapInt32BigToHost(*((*((uint32_t**)&readPos))++))
#define readUint64 CFSwapInt64BigToHost(*((*((uint64_t**)&readPos))++))
#define abortSwitch type = 0; break;
#define canRead(x) if (readPos-bytes+(x) > dataLength) {goto endOfBuffer;}



@interface GPGPacket (Private)

- (id)initWithBytes:(const uint8_t *)bytes length:(NSUInteger)dataLength nextPacketStart:(const uint8_t **)nextPacket;

@end


typedef enum {
	state_searchStart = 0,
	state_parseStart,
	state_waitForText,
	state_waitForEnd
} myState;



@implementation GPGPacket
@synthesize type, data, keyID, fingerprint, publicKeyAlgorithm, symetricAlgorithm, hashAlgorithm, signatureType, subpackets;


static const char armorBeginMark[] = "\n-----BEGIN PGP ";
const int armorBeginMarkLength = 16;
static const char armorEndMark[] = "\n-----END PGP ";
const int armorEndMarkLength = 14;
static const char *armorTypeStrings[] = { //The first byte contains the length of the string.
	"\x13SIGNED MESSAGE-----",
	"\x0cMESSAGE-----",
	"\x15PUBLIC KEY BLOCK-----",
	"\x0eSIGNATURE-----",
	"\021ARMORED FILE-----",
	"\x16PRIVATE KEY BLOCK-----",
	"\x15SECRET KEY BLOCK-----"
};
const int armorTypeStringsCount = 7;

//static const char clearTextBeginMark[] = "-----BEGIN PGP SIGNED MESSAGE-----";
//const int clearTextBeginMarkLength = 34;
//static const char clearTextEndMark[] = "-----BEGIN PGP SIGNATURE-----";
//const int clearTextEndMarkLength = 29;




+ (id)packetsWithData:(NSData *)theData {
	NSMutableArray *packets = [NSMutableArray array];
	
	
	
	theData = [self unArmor:theData];
	if ([theData length] < 10) {
		return nil;
	}
	const uint8_t *bytes = [theData bytes];
	
	
	const uint8_t *endPos = bytes + [theData length];
	const uint8_t *currentPos = bytes;
	const uint8_t *nextPacketPos = 0;
	
	while (currentPos < endPos) {
		nextPacketPos = 0;
		GPGPacket *packet = [[self alloc] initWithBytes:currentPos length:endPos - currentPos nextPacketStart:&nextPacketPos];
		if (packet) {
			[packets addObject:packet];
		}
		if (nextPacketPos <= currentPos) {
			break;
		} 
		currentPos = nextPacketPos;
	}
	
	
	return packets;
}


+ (void)enumeratePacketsWithData:(NSData *)theData block:(void (^)(GPGPacket *packet, BOOL *stop))block {
	theData = [self unArmor:theData];
	if ([theData length] < 10) {
		return;
	}
	const uint8_t *bytes = [theData bytes];
	
	
	const uint8_t *endPos = bytes + [theData length];
	const uint8_t *currentPos = bytes;
	const uint8_t *nextPacketPos = 0;
	BOOL stop = NO;
	
	while (currentPos < endPos) {
		nextPacketPos = 0;
		GPGPacket *packet = [[self alloc] initWithBytes:currentPos length:endPos - currentPos nextPacketStart:&nextPacketPos];
		if (packet) {
			block(packet, &stop);
			if (stop) {
				return;
			}
		}
		if (nextPacketPos <= currentPos) {
			break;
		}
		currentPos = nextPacketPos;
	}
}


- (id)initWithBytes:(const uint8_t *)bytes length:(NSUInteger)dataLength nextPacketStart:(const uint8_t **)nextPacket {
	if (!(self = [super init])) {
		return nil;
	}
	description = nil;
	
	const uint8_t *readPos = bytes;
	canRead(1);
	
	if (!(bytes[0] & 0x80)) {
		return nil;
	}
	
	BOOL newFormat = bytes[0] & 0x40;
	unsigned int length;
	
	if (newFormat) {
		type = *readPos & 0x3F;
		readPos++;
		const uint8_t *oldReadPos = readPos;
		
		length = 0;
		while (1) {
			canRead(1);
			if (*readPos < 192) {
				length += *readPos;
				readPos = oldReadPos + 1;
				break;
			} else if (*readPos < 224) {
				canRead(2);
				length += ((readPos[0] - 192) << 8) + readPos[1] + 192;
				readPos = oldReadPos + 2;
				break;
			} else if (*readPos == 255) {
				readPos++;
				canRead(4);
				length += readUint32;
				readPos = oldReadPos + 4;
				break;
			}
			//TODO: Full support for Partial Packets.
			unsigned int partLength = (1 << (*readPos & 0x1F)) + 1;
			readPos += partLength;
			length += partLength;
		}
		
	} else {
		type = (*readPos & 0x3C) >> 2;
		if (type == 0) {
			return nil;
		}
		switch (*(readPos++) & 3) {
			case 0:
				canRead(1);
				length = readUint8;
				break;
			case 1:
				canRead(2);
				length = readUint16;
				break;
			case 2:
				canRead(4);
				length = readUint32;
				break;
			default:
				length = dataLength - 1;
				break;
		}
	}
	canRead(length);
	data = [[NSData alloc] initWithBytes:bytes length:readPos - bytes + length];
	
	*nextPacket = readPos + length;
	
	
	
	
	switch (type) { //TODO: Parse packet content.
		case GPGPublicKeyEncryptedSessionKeyPacket:
			canRead(10);
			if (readUint8 != 3) {
				abortSwitch;
			}
			keyID = [[NSString alloc] initWithFormat:@"%016llX", readUint64];
			publicKeyAlgorithm = readUint8;
			break;
		case GPGSignaturePacket:
			canRead(12);
			switch (readUint8) {
				case 3:
					//TODO
					break;
				case 4: {
					signatureType = readUint8;
					publicKeyAlgorithm = readUint8;
					hashAlgorithm = readUint8;
					
					
					
					// Subpackets verarbeiten.
					subpackets = [[NSMutableArray alloc] init];
					
					for (int i = 0; i < 2; i++) { // Zweimal da es hashed und unhashed subpackets geben kann!
						const uint8_t *subpacketEnd = readUint16 + readPos;
						while (readPos < subpacketEnd) {
							NSMutableDictionary *subpacket = [[NSMutableDictionary alloc] init];
							
							uint32_t subpacketLength = readUint8;
							if (subpacketLength == 255) {
								subpacketLength = readUint32;
							} else if (subpacketLength >= 192) {
								subpacketLength = ((subpacketLength - 192) << 8) + readUint8 + 192;
							}
							uint8_t subpacketType = readUint8;
							
							[subpacket setObject:@(subpacketLength) forKey:@"length"];
							[subpacket setObject:@(subpacketType) forKey:@"type"];
														
							if (subpacketType == 16 && subpacketLength == 9) {
								keyID = bytesToHexString(readPos, 8);
							}
							
							
							[subpackets addObject:subpacket];
							
							readPos += subpacketLength - 1;
						}
					}
					
					
					break; }
			}
			break;
		case GPGSymmetricEncryptedSessionKeyPacket:
			canRead(2);
			if (readUint8 != 3) {
				abortSwitch;
			}
			symetricAlgorithm = readUint8;
			break;
		case GPGOnePassSignaturePacket:
			canRead(13);
			if (readUint8 != 4) {
				abortSwitch;
			}
			signatureType = readUint8;
			hashAlgorithm = readUint8;
			publicKeyAlgorithm = readUint8;
			keyID = [[NSString alloc] initWithFormat:@"%016llX", readUint64];
			break;
		case GPGPublicKeyPacket:
		case GPGPublicSubkeyPacket:
		case GPGSecretKeyPacket:
		case GPGSecretSubkeyPacket: {
			const uint8_t *packetStart = readPos;
			canRead(6);
			if (readUint8 != 4) {
				abortSwitch;
			}
			readPos += 4;
			publicKeyAlgorithm = readUint8;
			
			
			uint8_t bytesForSHA1[length + 3];
			bytesForSHA1[0] = 0x99;
			uint16_t temp = (uint16_t)length;
			bytesForSHA1[1] = ((uint8_t*)&temp)[1];
			bytesForSHA1[2] = ((uint8_t*)&temp)[0];
			memcpy(bytesForSHA1+3, packetStart, length);
			
			uint8_t fingerprintBytes[20];
			CC_SHA1(bytesForSHA1, length + 3, fingerprintBytes);
			fingerprint = bytesToHexString(fingerprintBytes, 20);
			keyID = [fingerprint keyID];
			
			break; }
		case GPGCompressedDataPacket:
			//TODO
			break;
		case GPGSymmetricEncryptedDataPacket:
			//TODO
			break;
		case GPGMarkerPacket:
			//TODO
			break;
		case GPGLiteralDataPacket:
			//TODO
			break;
		case GPGTrustPacket:
			//TODO
			break;
		case GPGUserIDPacket:
			//TODO
			break;
		case GPGUserAttributePacket:
			//TODO
			break;
		case GPGSymmetricEncryptedProtectedDataPacket:
			//TODO
			break;
		case GPGModificationDetectionCodePacket:
			//TODO
			break;
		default: //Unknown packet type.
			abortSwitch;
	}
	
	
	return self;
endOfBuffer:
	return nil;
}

- (id)init {
	return nil;
}



+ (NSData *)unArmor:(NSData *)theData {
	return [self unArmor:theData clearText:nil];
}

+ (NSData *)unArmor:(NSData *)theData clearText:(NSData **)clearText {
    GPGMemoryStream *input = [GPGMemoryStream memoryStreamForReading:theData];
    NSData *unarmored = [self unArmorFrom:input clearText:clearText];
    if ([unarmored length])
        return unarmored;
    return theData;
}

+ (NSData *)unArmorFrom:(GPGStream *)input clearText:(NSData **)clearText 
{
	if ([input length] < 50 || ![self isArmored:[input peekByte]]) {
		return nil;
	}

    NSData *theData = [input readAllData];
	const char *bytes = [theData bytes];
	NSUInteger dataLength = [theData length];
	const char *readPos, *endPos;
	const char *textStart, *textEnd;
	int newlineCount, armorType, maxCRToAdd = 0;
	BOOL haveClearText = NO;
	NSMutableData *decodedData = [NSMutableData data];
	myState state = state_searchStart;
	BOOL failed = NO;
	
	

	char *mutableBytes = malloc(dataLength);
	if (!mutableBytes) {
		NSLog(@"unArmorFrom:clearText: malloc failed!");
		failed = YES;
		goto endOfBuffer;
	}
	memcpy(mutableBytes, bytes, dataLength);
	char *mutableReadPos = mutableBytes;
	endPos = mutableBytes + dataLength;

	
	


	// Replace \r and \0 by \n.
	for (; mutableReadPos < endPos; mutableReadPos++) {
		switch (mutableReadPos[0]) {
			case '\r':
				if (mutableReadPos[1] != '\n') {
					mutableReadPos[0] = '\n';
				}
				break;
			case 0:
				mutableReadPos[0] = '\n';
			case '\n':
				maxCRToAdd++;
			default:
				break;
		}
	}
	readPos = bytes = mutableBytes;

	
	if (memcmp(armorBeginMark+1, readPos, armorBeginMarkLength - 1) == 0) {
		state = state_parseStart;
		readPos += armorBeginMarkLength - 1;
	}
	
	for (;readPos < endPos - 25; readPos++) {
		switch (state) {
			case state_searchStart:
				readPos = lm_memmem(readPos, endPos - readPos - 20, armorBeginMark, armorBeginMarkLength);
				if (!readPos) {
					goto endOfBuffer;
				}
				readPos += armorBeginMarkLength;
			case state_parseStart:
				canRead(40);
				
				if (haveClearText) {
					armorType = 3;
					if (memcmp(armorTypeStrings[armorType]+1, readPos, armorTypeStrings[armorType][0])) {
						GPGDebugLog(@"GPGPacket unarmor: \"-----BEGIN PGP SIGNATURE-----\" expected but not found.")
						goto endOfBuffer;
					}
					textEnd = readPos - armorBeginMarkLength;
					
					char *clearBytes = malloc(textEnd - textStart + maxCRToAdd);
					if (!clearBytes) {
						NSLog(@"unArmorFrom:clearText: malloc failed!");
						failed = YES;
						goto endOfBuffer;
					}
					if (textStart[0] == '-' && textStart[1] == ' ') {
						textStart += 2;
					}
					readPos = textStart;
					char *clearBytesPtr = clearBytes;
					const char *newlinePos;
					while ((newlinePos = memchr(readPos, '\n', textEnd - readPos))) {
						readPos = newlinePos - 1;
						if (*readPos == '\r') { // Remove \n as well as \r\n.
							readPos--;
						}
						
						while (*readPos == ' ' || *readPos == '\t') { // Remove spaces and tabs from the end of lines.
							readPos--;
						}
						
						readPos++;
						memcpy(clearBytesPtr, textStart, readPos - textStart);
						clearBytesPtr += readPos - textStart;
						
						clearBytesPtr[0] = '\r';
						clearBytesPtr[1] = '\n';
						clearBytesPtr += 2;

						
						readPos = newlinePos + 1;
						if (readPos[0] == '-' && readPos[1] == ' ') {
							readPos += 2;
						}
						textStart = readPos;
					}
					while (textEnd[-1] == ' ' || textEnd[-1] == '\t') { // Remove spaces and tabs from the end of the last line.
						textEnd--;
					}

					memcpy(clearBytesPtr, textStart, textEnd - textStart);
					clearBytesPtr += textEnd - textStart;
										
					*clearText = [NSData dataWithBytes:clearBytes length:clearBytesPtr - clearBytes];
					free(clearBytes);
					haveClearText = NO;
					
					readPos = textEnd + armorBeginMarkLength + armorTypeStrings[armorType][0];
					state = state_waitForText;
				} else {
					BOOL found = NO;
					for (armorType = 0; armorType < armorTypeStringsCount; armorType++) {
						if (memcmp(armorTypeStrings[armorType]+1, readPos, armorTypeStrings[armorType][0]) == 0) {						
							readPos += armorTypeStrings[armorType][0] - 1;
							
							if (armorType == 0) { //Is "-----BEGIN PGP SIGNED MESSAGE-----".
								if (clearText) {
									haveClearText = YES;
									found = YES;
								}
							} else {
								found = YES;
							}
							break;
						}
					}
					if (!found) {
						state = state_searchStart;
						break;
					}
					state = state_waitForText;
					readPos++;
				}
				newlineCount = 0;
			case state_waitForText:
				switch (*readPos) {
					case '\n':
						newlineCount++;
						if (newlineCount == 2) {
							state = haveClearText ? state_searchStart : state_waitForEnd;
							textStart = readPos + 1;
						}
					case '\r':
					case ' ':
					case '\t':
						break;
					default:
						newlineCount = 0;
				}
				break;
			case state_waitForEnd: {
				textEnd = lm_memmem(readPos, endPos - readPos, "\n=", 2);
				const char *crcPos = NULL;
				if (textEnd) {
					textEnd++;
					crcPos = textEnd + 1;
					readPos = textEnd + 5;
				}
				
				readPos = lm_memmem(readPos, endPos - readPos, armorEndMark, armorEndMarkLength);
				if (!readPos) {
					goto endOfBuffer;
				}
				
				if (!textEnd) {
					textEnd = readPos + 1;
				}
				
				
				readPos = readPos + armorEndMarkLength;
				int length = armorTypeStrings[armorType][0];
				canRead(length);
				if (memcmp(armorTypeStrings[armorType]+1, readPos, armorTypeStrings[armorType][0]) != 0) {
					goto endOfBuffer;
				}
				
				length = (textEnd - textStart) * 3 / 4;
				char *binaryBuffer = malloc(length);
				if (!binaryBuffer) {
					goto endOfBuffer;
				}
				
				BIO *filter = BIO_new(BIO_f_base64());
				BIO *bio = BIO_new_mem_buf((void *)textStart, textEnd - textStart);
				bio = BIO_push(filter, bio);
				length = BIO_read(bio, binaryBuffer, length);
				BIO_free_all(bio);
				
				
				if (crcPos) {
					uint32_t crc1, crc2;
					uint8_t crcBuffer[3];
					
					filter = BIO_new(BIO_f_base64());
					bio = BIO_new_mem_buf((void *)crcPos, 6);
					bio = BIO_push(filter, bio);
					int crcLength = BIO_read(bio, crcBuffer, 3);
					BIO_free_all(bio);
					
					if (crcLength != 3) {
						NSLog(@"unArmorFrom:clearText: %@", localizedLibmacgpgString(@"CRC Error"));
						failed = YES;
						goto endOfBuffer;
					}
					
					crc1 = (crcBuffer[0] << 16) + (crcBuffer[1] << 8) + crcBuffer[2];
					
					crc2 = crc24(binaryBuffer, length);
					if (crc1 != crc2) {
						NSLog(@"unArmorFrom:clearText: %@", localizedLibmacgpgString(@"CRC Error"));
						failed = YES;
						goto endOfBuffer;
					}
				}
				
				if (length > 0) {
					[decodedData appendBytes:binaryBuffer length:length];
				}
				free(binaryBuffer);
				
				
				readPos += armorTypeStrings[armorType][0] - 1;
				state = state_searchStart;
				break; }
		}		
	} //for
	
endOfBuffer:
	free(mutableBytes);
	if (failed) {
		return nil;
	}
	return decodedData;
}


long crc24(char *bytes, NSUInteger length) {
	long crc = 0xB704CEL;
	while (length--) {
		crc ^= (*bytes++) << 16;
		for (int i = 0; i < 8; i++) {
			crc <<= 1;
			if (crc & 0x1000000)
				crc ^= 0x1864CFBL;
		}
	}
	return crc & 0xFFFFFFL;
}


+ (BOOL)isArmored:(const uint8_t)byte {
	if (!(byte & 0x80)) {
		return YES;
	}
	switch ((byte & 0x40) ? (byte & 0x3F) : ((byte & 0x3C) >> 2)) {
		case GPGPublicKeyEncryptedSessionKeyPacket:
		case GPGSignaturePacket:
		case GPGSymmetricEncryptedSessionKeyPacket:
		case GPGOnePassSignaturePacket:
		case GPGPublicKeyPacket:
		case GPGPublicSubkeyPacket:
		case GPGSecretKeyPacket:
		case GPGSecretSubkeyPacket:
		case GPGCompressedDataPacket:
		case GPGSymmetricEncryptedDataPacket:
		case GPGMarkerPacket:
		case GPGLiteralDataPacket:
		case GPGTrustPacket:
		case GPGUserIDPacket:
		case GPGUserAttributePacket:
		case GPGSymmetricEncryptedProtectedDataPacket:
		case GPGModificationDetectionCodePacket:
			return NO;
	}
	return YES;
}



+ (NSData *)repairPacketData:(NSData *)theData {
	const char *bytes = [theData bytes];
	NSUInteger dataLength = [theData length];
	
	if (dataLength < 50 || ![self isArmored:*bytes]) {
		return theData;
	}
	
	const char *readPos = bytes;
	const char *endPos = bytes + dataLength;
	NSMutableData *repairedData = [NSMutableData data];
	
	
	readPos = lm_memmem(readPos, endPos - readPos - 20, armorBeginMark, armorBeginMarkLength);
	if (!readPos) {
		goto endOfBuffer;
	}
	
	//TODO
	
	
	
	
	
endOfBuffer:
	return repairedData;
}

- (NSString *)description {
	if (!description) {
		description = [[NSString alloc] initWithFormat:@"GPGPacket type: %i, keyID %@", self.type, self.keyID];
	}

	return description;
}


@end
