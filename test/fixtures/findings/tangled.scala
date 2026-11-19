object Tangled {
  def tied(a: Int, b: Int, c0: Int): Int = {
    var total = 0
    var c = c0
    for (i <- 0 until a) {
      if (i % 2 == 0) {
        for (j <- 0 until b) {
          if (j % 3 == 0) {
            while (c > 0) {
              if (c % 5 == 0 && i > 1) {
                total += 1
              } else if (c % 7 == 0 || j > 2) {
                total += 2
              } else {
                total -= 1
              }
              c -= 1
            }
          } else if (j % 4 == 0) {
            total += j
          }
        }
      } else if (i % 5 == 0) {
        total -= i
      }
    }
    total
  }
}
