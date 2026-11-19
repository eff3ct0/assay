export function knotted(a: number, b: number, c: number): number {
  let total = 0;
  for (let i = 0; i < a; i++) {
    if (i % 2 === 0) {
      for (let j = 0; j < b; j++) {
        if (j % 3 === 0) {
          while (c > 0) {
            if (c % 5 === 0 && i > 1) {
              total += 1;
            } else if (c % 7 === 0 || j > 2) {
              total += 2;
            } else {
              total -= 1;
            }
            c--;
          }
        } else if (j % 4 === 0) {
          total += j;
        }
      }
    } else if (i % 5 === 0) {
      total -= i;
    }
  }
  return total;
}
