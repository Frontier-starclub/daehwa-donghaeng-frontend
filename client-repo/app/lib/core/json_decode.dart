import 'api_exception.dart';

/// Convert malformed success responses to the same recoverable UI error.
T decodeResponse<T>(dynamic value, T Function(dynamic) decode) {
  try {
    return decode(value);
  } on FormatException catch (error) {
    throw ApiException.malformed(error);
  } on TypeError catch (error) {
    throw ApiException.malformed(error);
  }
}
