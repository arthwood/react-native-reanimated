#include <worklets/Tools/WorkletsJSIUtils.h>
#include <vector>

using namespace facebook;

namespace worklets::jsi_utils {

jsi::Array convertStringToArray(
    jsi::Runtime &rt,
    const std::string &value,
    const unsigned int expectedSize) {
  std::vector<float> transformMatrixList;
  std::istringstream stringStream(value);
  std::copy(
      std::istream_iterator<float>(stringStream),
      std::istream_iterator<float>(),
      std::back_inserter(transformMatrixList));
  assert(transformMatrixList.size() == expectedSize);
  jsi::Array matrix(rt, expectedSize);
  for (unsigned int i = 0; i < expectedSize; i++) {
    matrix.setValueAtIndex(rt, i, transformMatrixList[i]);
  }
  return matrix;
}

} // namespace worklets::jsi_utils
