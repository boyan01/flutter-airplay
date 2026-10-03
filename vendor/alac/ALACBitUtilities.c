/*
 * Copyright (c) 2011 Apple Inc. All rights reserved.
 *
 * @APPLE_APACHE_LICENSE_HEADER_START@
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * @APPLE_APACHE_LICENSE_HEADER_END@
 */
// Local modifications: bounded network input and decoder arithmetic; see UPSTREAM.md.


/*=============================================================================
    File:		ALACBitUtilities.c

	$NoKeywords: $
=============================================================================*/

#include <stdio.h>
#include "ALACBitUtilities.h"

// BitBufferInit
//
void BitBufferInit( BitBuffer * bits, uint8_t * buffer, uint32_t byteSize )
{
	bits->cur		= buffer;
	bits->end		= bits->cur + byteSize;
	bits->bitIndex	= 0;
	bits->byteSize	= byteSize;
	bits->error = 0;
}

// Local: bounded reads for packets received from the network.
static uint32_t ReadBits(BitBuffer *bits, uint8_t count)
{
    if (count > 32 || bits->error || (uint64_t)(bits->end - bits->cur) * 8 < bits->bitIndex + count) {
        bits->error = 1;
        bits->cur = bits->end;
        bits->bitIndex = 0;
        return 0;
    }
    uint32_t value = 0;
    while (count) {
        const uint8_t take = MIN(count, 8 - bits->bitIndex);
        value = (value << take) | ((*bits->cur >> (8 - bits->bitIndex - take)) & ((1u << take) - 1));
        count -= take;
        bits->bitIndex += take;
        bits->cur += bits->bitIndex >> 3;
        bits->bitIndex &= 7;
    }
    return value;
}
uint32_t BitBufferRead(BitBuffer *bits, uint8_t count) { return ReadBits(bits, count); }
uint8_t BitBufferReadSmall(BitBuffer *bits, uint8_t count) { return (uint8_t)ReadBits(bits, count); }
uint8_t BitBufferReadOne(BitBuffer *bits) { return (uint8_t)ReadBits(bits, 1); }
uint32_t BitBufferPeek(BitBuffer *bits, uint8_t count)
{
    BitBuffer copy = *bits;
    const uint32_t value = ReadBits(&copy, count);
    bits->error |= copy.error;
    return value;
}
uint32_t BitBufferPeekOne(BitBuffer *bits) { return BitBufferPeek(bits, 1); }

// BitBufferUnpackBERSize
//
uint32_t BitBufferUnpackBERSize( BitBuffer * bits )
{
	uint32_t		size;
	uint8_t		tmp;

	for ( size = 0, tmp = 0x80u; tmp &= 0x80u; size = (size << 7u) | (tmp & 0x7fu) )
		tmp = (uint8_t) BitBufferReadSmall( bits, 8 );

	return size;
}

// BitBufferGetPosition
//
uint32_t BitBufferGetPosition( BitBuffer * bits )
{
	uint8_t *		begin;

	begin = bits->end - bits->byteSize;

	return ((uint32_t)(bits->cur - begin) * 8) + bits->bitIndex;
}

// BitBufferByteAlign
//
void BitBufferByteAlign( BitBuffer * bits, int32_t addZeros )
{
	// align bit buffer to next byte boundary, writing zeros if requested
	if ( bits->bitIndex == 0 )
		return;

	if ( addZeros )
		BitBufferWrite( bits, 0, 8 - bits->bitIndex );
	else
		BitBufferAdvance( bits, 8 - bits->bitIndex );
}

// BitBufferAdvance
//
void BitBufferAdvance( BitBuffer * bits, uint32_t numBits )
{
	if ( numBits )
	{
        if ((uint64_t)(bits->end - bits->cur) * 8 < (uint64_t)bits->bitIndex + numBits) {
            bits->error = 1;
            bits->cur = bits->end;
            bits->bitIndex = 0;
            return;
        }
		bits->bitIndex += numBits;
		bits->cur += (bits->bitIndex >> 3);
		bits->bitIndex &= 7;
	}
}

// BitBufferRewind
//
void BitBufferRewind( BitBuffer * bits, uint32_t numBits )
{
	uint32_t	numBytes;

	if ( numBits == 0 )
		return;

	if ( bits->bitIndex >= numBits )
	{
		bits->bitIndex -= numBits;
		return;
	}

	numBits -= bits->bitIndex;
	bits->bitIndex = 0;

	numBytes	= numBits / 8;
	numBits		= numBits % 8;

	bits->cur -= numBytes;

	if ( numBits > 0 )
	{
		bits->bitIndex = 8 - numBits;
		bits->cur--;
	}

	if ( bits->cur < (bits->end - bits->byteSize) )
	{
		//DebugCMsg("BitBufferRewind: Rewound too far.");

		bits->cur		= (bits->end - bits->byteSize);
		bits->bitIndex	= 0;
	}
}

// BitBufferWrite
//
void BitBufferWrite( BitBuffer * bits, uint32_t bitValues, uint32_t numBits )
{
	uint32_t				invBitIndex;

	RequireAction( bits != nil, return; );
	RequireActionSilent( numBits > 0, return; );

	invBitIndex = 8 - bits->bitIndex;

	while ( numBits > 0 )
	{
		uint32_t		tmp;
		uint8_t		shift;
		uint8_t		mask;
		uint32_t		curNum;

		curNum = MIN( invBitIndex, numBits );

		tmp = bitValues >> (numBits - curNum);

		shift  = (uint8_t)(invBitIndex - curNum);
		mask   = 0xffu >> (8 - curNum);		// must be done in two steps to avoid compiler sequencing ambiguity
		mask <<= shift;

		bits->cur[0] = (bits->cur[0] & ~mask) | (((uint8_t) tmp << shift)  & mask);
		numBits -= curNum;

		// increment to next byte if need be
		invBitIndex -= curNum;
		if ( invBitIndex == 0 )
		{
			invBitIndex = 8;
			bits->cur++;
		}
	}

	bits->bitIndex = 8 - invBitIndex;
}

void	BitBufferReset( BitBuffer * bits )
//void BitBufferInit( BitBuffer * bits, uint8_t * buffer, uint32_t byteSize )
{
	bits->cur		= bits->end - bits->byteSize;
    bits->bitIndex	= 0;
}

#if PRAGMA_MARK
#pragma mark -
#endif
