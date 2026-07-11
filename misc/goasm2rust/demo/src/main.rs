unsafe extern "C" {
    fn go_xor_bytes_sse2(dst: *mut u8, a: *const u8, b: *const u8, n: usize);
}

fn main() {
    for n in [1usize, 7, 8, 15, 16, 17, 64, 100, 1000] {
        let a: Vec<u8> = (0..n).map(|i| (i * 7 + 13) as u8).collect();
        let b: Vec<u8> = (0..n).map(|i| (i * 31 + 5) as u8).collect();
        let mut dst = vec![0u8; n];
        unsafe { go_xor_bytes_sse2(dst.as_mut_ptr(), a.as_ptr(), b.as_ptr(), n) };
        let want: Vec<u8> = a.iter().zip(&b).map(|(x, y)| x ^ y).collect();
        assert_eq!(dst, want, "mismatch at n={n}");
        println!("n={n:5} OK");
    }
    println!("Go assembly running inside a Rust binary ✔");
}
