pub fn snarled(a: u32, b: u32, mut c: u32) -> i64 {
    let mut total = 0i64;
    for i in 0..a {
        if i % 2 == 0 {
            for j in 0..b {
                if j % 3 == 0 {
                    while c > 0 {
                        if c % 5 == 0 && i > 1 {
                            total += 1;
                        } else if c % 7 == 0 || j > 2 {
                            total += 2;
                        } else {
                            total -= 1;
                        }
                        c -= 1;
                    }
                } else if j % 4 == 0 {
                    total += j as i64;
                }
            }
        } else if i % 5 == 0 {
            total -= i as i64;
        }
    }
    total
}
