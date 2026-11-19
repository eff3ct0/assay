def tangled(a, b, c, d):
    total = 0
    for i in range(a):
        if i % 2 == 0:
            for j in range(b):
                if j % 3 == 0:
                    while c > 0:
                        if d and c % 5 == 0:
                            total += 1
                        elif d or c % 7 == 0:
                            total += 2
                        else:
                            total -= 1
                        c -= 1
                elif j % 4 == 0:
                    total += j
        elif i % 5 == 0:
            total -= i
    return total
