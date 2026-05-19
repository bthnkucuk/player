import 'package:equatable/equatable.dart';

/// Enable global Equatable stringify so failure diffs in assertions show
/// field values instead of just the class name. Call once from a `setUpAll`
/// in each test file.
///
/// In pure-Dart `package:test` there is no `flutter_test_config.dart`
/// magic-file equivalent, so each test opts in explicitly.
void enableEquatableStringify() {
  EquatableConfig.stringify = true;
}
