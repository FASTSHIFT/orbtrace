/* Minimal non-interactive ETM3.5 decoder using orbuculum's traceDecoder lib.
 * Reads a raw ETM3.5 byte stream from a file, prints each resolved address
 * (PC) and the executed/non-executed atom counts. Map addresses to function
 * names with arm-none-eabi-addr2line (done by the wrapper script).
 *
 * Build (from orbuculum repo root):
 *   cc -I Inc -I Inc/external etmdecode.c \
 *      Src/traceDecoder.c Src/traceDecoder_etm35.c Src/traceDecoder_etm4.c \
 *      Src/traceDecoder_mtb.c Src/generics.c -o /tmp/etmdecode
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include "traceDecoder.h"

static void cb( void *d )
{
    struct TRACEDecoder *t = ( struct TRACEDecoder * )d;
    struct TRACECPUState *cpu = &t->cpu;

    if ( TRACEStateChanged( t, EV_CH_ADDRESS ) )
    {
        printf( "ADDR 0x%08x\n", ( unsigned )cpu->addr );
    }
    if ( TRACEStateChanged( t, EV_CH_ENATOMS ) )
    {
        /* executed/non-executed atoms since last - flow detail */
        printf( "ATOMS e=%u n=%u addr=0x%08x\n",
                cpu->eatoms, cpu->natoms, ( unsigned )cpu->addr );
    }
    if ( TRACEStateChanged( t, EV_CH_EX_ENTRY ) )
    {
        printf( "EXCEPTION enter %u\n", cpu->exception );
    }
}

int main( int argc, char *argv[] )
{
    if ( argc < 2 )
    {
        fprintf( stderr, "usage: %s <etm35-file>\n", argv[0] );
        return 1;
    }

    FILE *f = fopen( argv[1], "rb" );
    if ( !f ) { perror( "open" ); return 1; }

    struct TRACEDecoder t;
    TRACEDecoderInit( &t, TRACE_PROT_ETM35, false, NULL );

    uint8_t buf[4096];
    size_t n;
    uint64_t total = 0;
    while ( ( n = fread( buf, 1, sizeof( buf ), f ) ) > 0 )
    {
        TRACEDecoderPump( &t, buf, n, cb, &t );
        total += n;
    }
    fclose( f );

    struct TRACEDecoderStats *s = TRACEDecoderGetStats( &t );
    fprintf( stderr, "decoded %llu bytes; sync=%u lostSync=%u\n",
             ( unsigned long long )total, s->syncCount, s->lostSyncCount );
    return 0;
}
