/* C-ABI wrapper around Go ABI0 assembly extracted from
   go/src/crypto/cipher/xor_amd64.s (func xorBytesSSE2).

   SysV args: rdi=dst, rsi=a, rdx=b, rcx=n
   Go ABI0 expects them in the caller's stack frame: after our CALL pushes
   the return address, the body reads dst at 0x8(%rsp) .. n at 0x20(%rsp).
   The Go code clobbers %rbx (scratch in Go ABI0, callee-saved in SysV),
   so we preserve it here. */
    .text
    .globl go_xor_bytes_sse2
    .type  go_xor_bytes_sse2, @function
go_xor_bytes_sse2:
    push   %rbx
    sub    $0x20, %rsp
    mov    %rdi, 0x0(%rsp)
    mov    %rsi, 0x8(%rsp)
    mov    %rdx, 0x10(%rsp)
    mov    %rcx, 0x18(%rsp)
    call   .Lgo_body
    add    $0x20, %rsp
    pop    %rbx
    ret
.Lgo_body:
#include "body.inc"
    .size go_xor_bytes_sse2, . - go_xor_bytes_sse2
    .section .note.GNU-stack,"",@progbits
