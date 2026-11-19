package tangled

func Knotted(a, b, c int) int {
	total := 0
	for i := 0; i < a; i++ {
		if i%2 == 0 {
			for j := 0; j < b; j++ {
				if j%3 == 0 {
					for c > 0 {
						if c%5 == 0 && i > 1 {
							total += 1
						} else if c%7 == 0 || j > 2 {
							total += 2
						} else {
							total -= 1
						}
						c--
					}
				} else if j%4 == 0 {
					total += j
				}
			}
		} else if i%5 == 0 {
			total -= i
		}
	}
	return total
}
