def summarize(rows):
    count = 0
    total = 0
    largest = None
    smallest = None
    for row in rows:
        count += 1
        total += row
        if largest is None or row > largest:
            largest = row
        if smallest is None or row < smallest:
            smallest = row
    mean = total / count if count else 0
    spread = largest - smallest if count else 0
    report = {}
    report["count"] = count
    report["total"] = total
    report["mean"] = mean
    report["spread"] = spread
    return report
