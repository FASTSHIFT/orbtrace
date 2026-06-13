/* etmdecode2: ETM3.5 decoder that FORCE-SYNCS at each A-sync.
 *
 * The stock decoder needs an in-IDLE I-SYNC (0x08) to set rxedISYNC before it
 * reports addresses; if it derails on a variable-length packet it stays lost
 * until it re-aligns. Real ETM A-sync (00 00 00 00 00 80) is a hard
 * byte-alignment + IDLE point. Here we scan for A-sync ourselves and call
 * TRACEDecoderForceSync at each, so the engine re-enters IDLE cleanly and
 * picks up the following I-SYNC. Reports resolved flash PCs.
 *
 * Build (from orbuculum repo root):
 *   cc -I Inc -I Inc/external etmdecode2.c \
 *      Src/traceDecoder.c Src/traceDecoder_etm35.c Src/traceDecoder_etm4.c \
 *      Src/traceDecoder_mtb.c Src/generics.c -o /tmp/etmdecode2
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include "traceDecoder.h"

static unsigned addr_hits = 0, flash_hits = 0;

static void cb( void *d )
{
    struct TRACEDecoder *t = ( struct TRACEDecoder * )d;
    struct TRACECPUState *cpu = &t->cpu;

    if ( TRACEStateChanged( t, EV_CH_ADDRESS ) )
    {
        addr_hits++;
        if ( ( cpu->addr & 0xFFF00000 ) == 0x08000000 )
        {
            flash_hits++;
            printf( "0x%08x\n", ( unsigned )cpu->addr );
        }
    }
}

int main( int argc, char *argv[] )
{
    if ( argc < 2 ) { fprintf( stderr, "usage: %s <etm35-file>\n", argv[0] ); return 1; }
    FILE *f = fopen( argv[1], "rb" );
    if ( !f ) { perror( "open" ); return 1; }

    uint8_t *buf = malloc( 1 << 20 );
    size_t len = fread( buf, 1, 1 << 20, f );
    fclose( f );

    struct TRACEDecoder t;
    TRACEDecoderInit( &t, TRACE_PROT_ETM35, false, NULL );

    /* A-sync = >=5 zero bytes then 0x80. Force-sync the engine at each, then
     * pump the bytes from just after the 0x80. */
    size_t i = 0;
    size_t seg_start = 0;
    unsigned zeros = 0;
    unsigned forced = 0;
    while ( i < len )
    {
        if ( buf[i] == 0x00 )
        {
            zeros++;
            i++;
            continue;
        }

        if ( ( zeros >= 5 ) && ( buf[i] == 0x80 ) )
        {
            /* pump the segment up to here, then force re-sync */
            if ( i > seg_start )
            {
                TRACEDecoderPump( &t, buf + seg_start, ( i - seg_start ), cb, &t );
            }

            TRACEDecoderForceSync( &t, true );
            forced++;
            i++;                 /* skip the 0x80 */
            seg_start = i;
            zeros = 0;
            continue;
        }

        zeros = 0;
        i++;
    }
    if ( len > seg_start )
    {
        TRACEDecoderPump( &t, buf + seg_start, ( len - seg_start ), cb, &t );
    }

    struct TRACEDecoderStats *s = TRACEDecoderGetStats( &t );
    fprintf( stderr, "forced-syncs=%u addr_events=%u flash_hits=%u sync=%u lostSync=%u\n",
             forced, addr_hits, flash_hits, s->syncCount, s->lostSyncCount );
    free( buf );
    return 0;
}
