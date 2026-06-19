.syntax unified
.thumb
.text
.global _start
_start:
@ r0 = ITM stimulus port 0 (0xE0000000)
@ r1 = byte to send
@ r3 = delay reload count
loop:
    str   r1, [r0]      @ write byte to ITM port 0
    mov   r2, r3        @ load delay counter
delay:
    subs  r2, r2, #1    @ decrement
    bne   delay         @ loop until zero
    b     loop          @ send next byte
