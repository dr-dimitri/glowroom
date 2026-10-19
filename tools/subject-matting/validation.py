"""Pure NumPy qualification gates; fail closed before emitting passing metrics."""
import math
import numpy as np


def validate_array(value, *, shape=None, coverage=False):
    array = np.asarray(value)
    if array.size == 0 or (shape is not None and array.shape != tuple(shape)):
        raise ValueError("Prediction has an invalid shape")
    if not np.isfinite(array).all():
        raise ValueError("Prediction contains non-finite values")
    if coverage and (array.min() < 0 or array.max() > 1):
        raise ValueError("Alpha coverage outside [0,1]")
    return array


def compare(reference, actual, *, shape=None, coverage=False,
            mean_limit=None, p99_limit=None, maximum_limit=None):
    expected = validate_array(reference, shape=shape, coverage=coverage)
    result = validate_array(actual, shape=expected.shape, coverage=coverage)
    error = np.abs(expected.astype(np.float64) - result.astype(np.float64))
    if not np.isfinite(error).all():
        raise ValueError("Difference contains non-finite values")
    metrics = {"meanAbsoluteError": float(error.mean()), "maximumAbsoluteError": float(error.max()),
               "p99AbsoluteError": float(np.percentile(error, 99))}
    if not all(math.isfinite(value) for value in metrics.values()):
        raise ValueError("Non-finite qualification metrics")
    for key, limit in (("meanAbsoluteError", mean_limit), ("p99AbsoluteError", p99_limit),
                       ("maximumAbsoluteError", maximum_limit)):
        if limit is not None and metrics[key] > limit:
            raise ValueError(f"{key} {metrics[key]} exceeds {limit}")
    return metrics
