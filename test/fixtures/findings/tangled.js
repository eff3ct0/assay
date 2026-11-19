function braided(items, limit, depth) {
  const seen = [];
  for (const item of items) {
    if (item.kind === "group") {
      for (const child of item.children) {
        if (child.size > limit) {
          while (depth > 0) {
            if (child.size % depth === 0 && item.open) {
              seen.push(child.name);
            } else if (child.size % 3 === 0 || item.shared) {
              seen.push(item.name);
            } else {
              seen.pop();
            }
            depth -= 1;
          }
        } else if (child.size === limit) {
          seen.push(child.id);
        }
      }
    } else if (item.kind === "leaf") {
      seen.push(item.id);
    }
  }
  return seen;
}
