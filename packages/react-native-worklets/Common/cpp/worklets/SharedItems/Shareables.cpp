#include <worklets/SharedItems/Shareables.h>

using namespace facebook;

namespace worklets {

jsi::Function getValueUnpacker(jsi::Runtime &rt) {
  auto valueUnpacker = rt.global().getProperty(rt, "__valueUnpacker");
  assert(valueUnpacker.isObject() && "valueUnpacker not found");
  return valueUnpacker.asObject(rt).asFunction(rt);
}

#ifndef NDEBUG

static const auto callGuardLambda = [](facebook::jsi::Runtime &rt,
                                       const facebook::jsi::Value &thisVal,
                                       const facebook::jsi::Value *args,
                                       size_t count) {
  return args[0].asObject(rt).asFunction(rt).call(rt, args + 1, count - 1);
};

jsi::Function getCallGuard(jsi::Runtime &rt) {
  auto callGuard = rt.global().getProperty(rt, "__callGuardDEV");
  if (callGuard.isObject()) {
    // Use JS implementation if `__callGuardDEV` has already been installed.
    // This is the desired behavior.
    return callGuard.asObject(rt).asFunction(rt);
  }

  // Otherwise, fallback to C++ JSI implementation. This is necessary so that we
  // can install `__callGuardDEV` itself and should happen only once. Note that
  // the C++ implementation doesn't intercept errors and simply throws them as
  // C++ exceptions which crashes the app. We assume that installing the guard
  // doesn't throw any errors.
  return jsi::Function::createFromHostFunction(
      rt, jsi::PropNameID::forAscii(rt, "callGuard"), 1, callGuardLambda);
}

#endif // NDEBUG

jsi::Value makeShareableClone(
    jsi::Runtime &rt,
    const jsi::Value &value,
    const jsi::Value &shouldRetainRemote,
    const jsi::Value &nativeStateSource) {
  std::shared_ptr<Shareable> shareable;
  if (value.isObject()) {
    auto object = value.asObject(rt);
    if (!object.getProperty(rt, "__workletHash").isUndefined()) {
      if (shouldRetainRemote.isBool() && shouldRetainRemote.getBool()) {
        shareable =
            std::make_shared<RetainingShareable<ShareableWorklet>>(rt, object);
      } else {
        shareable = std::make_shared<ShareableWorklet>(rt, object);
      }
    } else if (!object.getProperty(rt, "__init").isUndefined()) {
      shareable = std::make_shared<ShareableHandle>(rt, object);
    } else if (object.isFunction(rt)) {
      auto function = object.asFunction(rt);
      if (function.isHostFunction(rt)) {
        shareable =
            std::make_shared<ShareableHostFunction>(rt, std::move(function));
      } else {
        shareable =
            std::make_shared<ShareableRemoteFunction>(rt, std::move(function));
      }
    } else if (object.isArray(rt)) {
      if (shouldRetainRemote.isBool() && shouldRetainRemote.getBool()) {
        shareable = std::make_shared<RetainingShareable<ShareableArray>>(
            rt, object.asArray(rt));
      } else {
        shareable = std::make_shared<ShareableArray>(rt, object.asArray(rt));
      }
    } else if (object.isArrayBuffer(rt)) {
      shareable =
          std::make_shared<ShareableArrayBuffer>(rt, object.getArrayBuffer(rt));
    } else if (object.isHostObject(rt)) {
      if (object.isHostObject<ShareableJSRef>(rt)) {
        return object;
      }
      shareable =
          std::make_shared<ShareableHostObject>(rt, object.getHostObject(rt));
    } else {
      if (shouldRetainRemote.isBool() && shouldRetainRemote.getBool()) {
        shareable = std::make_shared<RetainingShareable<ShareableObject>>(
            rt, object, nativeStateSource);
      } else {
        shareable =
            std::make_shared<ShareableObject>(rt, object, nativeStateSource);
      }
    }
  } else if (value.isString()) {
    shareable = std::make_shared<ShareableString>(value.asString(rt).utf8(rt));
  } else if (value.isUndefined()) {
    shareable = std::make_shared<ShareableScalar>();
  } else if (value.isNull()) {
    shareable = std::make_shared<ShareableScalar>(nullptr);
  } else if (value.isBool()) {
    shareable = std::make_shared<ShareableScalar>(value.getBool());
  } else if (value.isNumber()) {
    shareable = std::make_shared<ShareableScalar>(value.getNumber());
  } else if (value.isBigInt()) {
    shareable = std::make_shared<ShareableBigInt>(rt, value.getBigInt(rt));
  } else if (value.isSymbol()) {
    // TODO: this is only a placeholder implementation, here we replace symbols
    // with strings in order to make certain objects to be captured. There isn't
    // yet any usecase for using symbols on the UI runtime so it is fine to keep
    // it like this for now.
    shareable =
        std::make_shared<ShareableString>(value.getSymbol(rt).toString(rt));
  } else {
    throw std::runtime_error(
        "[Worklets] Attempted to convert an unsupported value type.");
  }
  return ShareableJSRef::newHostObject(rt, shareable);
}

jsi::Value makeShareableString(jsi::Runtime &rt, const jsi::String &string) {
  auto shareable = std::make_shared<ShareableString>(string.utf8(rt));
  return ShareableJSRef::newHostObject(rt, shareable);
}

jsi::Value makeShareableNumber(jsi::Runtime &rt, double number) {
  auto shareable = std::make_shared<ShareableScalar>(number);
  return ShareableJSRef::newHostObject(rt, shareable);
}

jsi::Value makeShareableBoolean(jsi::Runtime &rt, bool boolean) {
  auto shareable = std::make_shared<ShareableScalar>(boolean);
  return ShareableJSRef::newHostObject(rt, shareable);
}

jsi::Value makeShareableBigInt(jsi::Runtime &rt, const jsi::BigInt &bigint) {
  auto shareable = std::make_shared<ShareableBigInt>(rt, bigint);
  return ShareableJSRef::newHostObject(rt, shareable);
}

jsi::Value makeShareableUndefined(jsi::Runtime &rt) {
  auto shareable = std::make_shared<ShareableScalar>();
  return ShareableJSRef::newHostObject(rt, shareable);
}

jsi::Value makeShareableNull(jsi::Runtime &rt) {
  auto shareable = std::make_shared<ShareableScalar>(nullptr);
  return ShareableJSRef::newHostObject(rt, shareable);
}

std::shared_ptr<Shareable> extractShareableOrThrow(
    jsi::Runtime &rt,
    const jsi::Value &maybeShareableValue,
    const std::string &errorMessage) {
  if (maybeShareableValue.isObject()) {
    auto object = maybeShareableValue.asObject(rt);
    if (object.isHostObject<ShareableJSRef>(rt)) {
      return object.getHostObject<ShareableJSRef>(rt)->value();
    }
    throw std::runtime_error(
        "[Worklets] Attempted to extract from a HostObject that wasn't converted to a Shareable.");
  } else if (maybeShareableValue.isUndefined()) {
    return Shareable::undefined();
  }
  throw std::runtime_error(errorMessage);
}

Shareable::~Shareable() {}

std::shared_ptr<Shareable> Shareable::undefined() {
  static auto undefined = std::make_shared<ShareableScalar>();
  return undefined;
}

template <typename BaseClass>
jsi::Value RetainingShareable<BaseClass>::toJSValue(jsi::Runtime &rt) {
  if (&rt == primaryRuntime_) {
    // TODO: it is suboptimal to generate new object every time getJS is
    // called on host runtime – the objects we are generating already exists
    // and we should possibly just grab a hold of such object and use it here
    // instead of creating a new JS representation. As far as I understand the
    // only case where it can be realistically called this way is when a
    // shared value is created and then accessed on the same runtime
    return BaseClass::toJSValue(rt);
  }
  if (secondaryValue_ == nullptr) {
    auto value = BaseClass::toJSValue(rt);
    secondaryValue_ = std::make_unique<jsi::Value>(rt, value);
    secondaryRuntime_ = &rt;
    return value;
  }
  if (&rt == secondaryRuntime_) {
    return jsi::Value(rt, *secondaryValue_);
  }
  return BaseClass::toJSValue(rt);
}

ShareableJSRef::~ShareableJSRef() {}

ShareableArray::ShareableArray(jsi::Runtime &rt, const jsi::Array &array)
    : Shareable(ArrayType) {
  auto size = array.size(rt);
  data_.reserve(size);
  for (size_t i = 0; i < size; i++) {
    data_.push_back(extractShareableOrThrow(rt, array.getValueAtIndex(rt, i)));
  }
}

jsi::Value ShareableArray::toJSValue(jsi::Runtime &rt) {
  auto size = data_.size();
  auto ary = jsi::Array(rt, size);
  for (size_t i = 0; i < size; i++) {
    ary.setValueAtIndex(rt, i, data_[i]->toJSValue(rt));
  }
  return ary;
}

jsi::Value ShareableArrayBuffer::toJSValue(jsi::Runtime &rt) {
  auto size = static_cast<int>(data_.size());
  auto arrayBuffer = rt.global()
                         .getPropertyAsFunction(rt, "ArrayBuffer")
                         .callAsConstructor(rt, size)
                         .getObject(rt)
                         .getArrayBuffer(rt);
  memcpy(arrayBuffer.data(rt), data_.data(), size);
  return arrayBuffer;
}

ShareableObject::ShareableObject(jsi::Runtime &rt, const jsi::Object &object)
    : Shareable(ObjectType) {
  auto propertyNames = object.getPropertyNames(rt);
  auto size = propertyNames.size(rt);
  data_.reserve(size);
  for (size_t i = 0; i < size; i++) {
    auto key = propertyNames.getValueAtIndex(rt, i).asString(rt);
    auto value = extractShareableOrThrow(rt, object.getProperty(rt, key));
    data_.emplace_back(key.utf8(rt), value);
  }
  if (object.hasNativeState(rt)) {
    nativeState_ = object.getNativeState(rt);
  }
}

ShareableObject::ShareableObject(
    jsi::Runtime &rt,
    const jsi::Object &object,
    const jsi::Value &nativeStateSource)
    : ShareableObject(rt, object) {
  if (nativeStateSource.isObject() &&
      nativeStateSource.asObject(rt).hasNativeState(rt)) {
    nativeState_ = nativeStateSource.asObject(rt).getNativeState(rt);
  }
}

jsi::Value ShareableObject::toJSValue(jsi::Runtime &rt) {
  auto obj = jsi::Object(rt);
  for (size_t i = 0, size = data_.size(); i < size; i++) {
    obj.setProperty(
        rt,
        jsi::String::createFromUtf8(rt, data_[i].first),
        data_[i].second->toJSValue(rt));
  }
  if (nativeState_ != nullptr) {
    obj.setNativeState(rt, nativeState_);
  }
  return obj;
}

jsi::Value ShareableHostObject::toJSValue(jsi::Runtime &rt) {
  return jsi::Object::createFromHostObject(rt, hostObject_);
}

jsi::Value ShareableHostFunction::toJSValue(jsi::Runtime &rt) {
  return jsi::Function::createFromHostFunction(
      rt, jsi::PropNameID::forUtf8(rt, name_), paramCount_, hostFunction_);
}

jsi::Value ShareableWorklet::toJSValue(jsi::Runtime &rt) {
  assert(
      std::any_of(
          data_.cbegin(),
          data_.cend(),
          [](const auto &item) { return item.first == "__workletHash"; }) &&
      "ShareableWorklet doesn't have `__workletHash` property");
  jsi::Value obj = ShareableObject::toJSValue(rt);
  return getValueUnpacker(rt).call(
      rt, obj, jsi::String::createFromAscii(rt, "Worklet"));
}

jsi::Value ShareableRemoteFunction::toJSValue(jsi::Runtime &rt) {
  if (&rt == runtime_) {
    return jsi::Value(rt, *function_);
  } else {
#ifndef NDEBUG
    return getValueUnpacker(rt).call(
        rt,
        ShareableJSRef::newHostObject(rt, shared_from_this()),
        jsi::String::createFromAscii(rt, "RemoteFunction"),
        jsi::String::createFromUtf8(rt, name_));
#else
    return ShareableJSRef::newHostObject(rt, shared_from_this());
#endif
  }
}

jsi::Value ShareableHandle::toJSValue(jsi::Runtime &rt) {
  if (remoteValue_ == nullptr) {
    auto initObj = initializer_->toJSValue(rt);
    auto value = std::make_unique<jsi::Value>(getValueUnpacker(rt).call(
        rt, initObj, jsi::String::createFromAscii(rt, "Handle")));

    // We are locking the initialization here since the thread that is
    // initalizing can be pre-empted on runtime lock. E.g.
    // UI thread can be pre-empted on initialization of a shared value and then
    // JS thread can try to access the shared value, locking the whole runtime.
    // If we put the lock on `getValueUnpacker` part (basically any part that
    // requires runtime) we would get a deadlock since UI thread would never
    // release it.
    std::unique_lock<std::mutex> lock(initializationMutex_);
    if (remoteValue_ == nullptr) {
      remoteValue_ = std::move(value);
      remoteRuntime_ = &rt;
    }
  }
  if (&rt == remoteRuntime_) {
    return jsi::Value(rt, *remoteValue_);
  }
  auto initObj = initializer_->toJSValue(rt);
  return getValueUnpacker(rt).call(
      rt, initObj, jsi::String::createFromAscii(rt, "Handle"));
}

jsi::Value ShareableString::toJSValue(jsi::Runtime &rt) {
  return jsi::String::createFromUtf8(rt, data_);
}

jsi::Value ShareableBigInt::toJSValue(jsi::Runtime &rt) {
  return rt.global()
      .getPropertyAsFunction(rt, "BigInt")
      .call(rt, jsi::String::createFromUtf8(rt, string_));
}

jsi::Value ShareableScalar::toJSValue(jsi::Runtime &) {
  switch (valueType_) {
    case Shareable::UndefinedType:
      return jsi::Value();
    case Shareable::NullType:
      return jsi::Value(nullptr);
    case Shareable::BooleanType:
      return jsi::Value(data_.boolean);
    case Shareable::NumberType:
      return jsi::Value(data_.number);
    default:
      throw std::runtime_error(
          "[Worklets] Attempted to convert object that's not of a scalar type.");
  }
}

} // namespace worklets
