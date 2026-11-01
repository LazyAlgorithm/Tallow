#include <enet/enet.h>
#include <stdint.h>
/* ENet counters include UDP datagrams, protocol headers, compression and retransmissions. */
uint32_t tallow_net_sent(const ENetHost *host) { return host ? host->totalSentData : 0; }
uint32_t tallow_net_received(const ENetHost *host) { return host ? host->totalReceivedData : 0; }

/* The same lossless codec as ENet, exposed independently for Steam/WebRTC application messages. */
void *tallow_net_codec_create(void) { return enet_range_coder_create(); }
void tallow_net_codec_destroy(void *codec) { if (codec) enet_range_coder_destroy(codec); }
uint32_t tallow_net_compress(void *codec, const uint8_t *data, uint32_t length, uint8_t *output, uint32_t capacity) {
    ENetBuffer buffer; buffer.data=(void *)data;buffer.dataLength=length;
    return codec ? (uint32_t)enet_range_coder_compress(codec,&buffer,1,length,output,capacity) : 0;
}
uint32_t tallow_net_decompress(void *codec, const uint8_t *data, uint32_t length, uint8_t *output, uint32_t capacity) {
    return codec ? (uint32_t)enet_range_coder_decompress(codec,data,length,output,capacity) : 0;
}
