"""Hypothesis's profiles for the repo's tests.

assay check runs pytest with Hypothesis's ci profile: derandomized, with no database
and no deadline. The explore profile tries inputs at random, ASSAY_CASES of them when
it is set: ASSAY_CASES=10000 pytest --hypothesis-profile=explore
"""

import os

from hypothesis import settings

settings.register_profile(
    "explore",
    max_examples=int(os.environ.get("ASSAY_CASES", settings().max_examples)),
)
