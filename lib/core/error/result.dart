/// A tiny `Result` type so fallible operations are explicit in their
/// signatures instead of relying on the caller remembering to catch.
library;

import 'package:flutter/foundation.dart';

import 'failure.dart';

@immutable
sealed class Result<T> {
  const Result();

  const factory Result.ok(T value) = Ok<T>;
  const factory Result.err(Failure failure) = Err<T>;

  bool get isOk => this is Ok<T>;
  bool get isErr => this is Err<T>;

  /// The value, or `null` when this is an error.
  T? get valueOrNull => switch (this) {
    Ok<T>(:final value) => value,
    Err<T>() => null,
  };

  /// The failure, or `null` when this is a success.
  Failure? get failureOrNull => switch (this) {
    Ok<T>() => null,
    Err<T>(:final failure) => failure,
  };

  T getOrElse(T fallback) => valueOrNull ?? fallback;

  /// Throws the failure as an exception. Only for tests and top-level guards.
  T unwrap() => switch (this) {
    Ok<T>(:final value) => value,
    Err<T>(:final failure) => throw StateError(failure.toString()),
  };

  Result<R> map<R>(R Function(T value) transform) => switch (this) {
    Ok<T>(:final value) => Result<R>.ok(transform(value)),
    Err<T>(:final failure) => Result<R>.err(failure),
  };

  Result<R> flatMap<R>(Result<R> Function(T value) transform) => switch (this) {
    Ok<T>(:final value) => transform(value),
    Err<T>(:final failure) => Result<R>.err(failure),
  };

  Future<Result<R>> mapAsync<R>(Future<R> Function(T value) transform) async =>
      switch (this) {
        Ok<T>(:final value) => Result<R>.ok(await transform(value)),
        Err<T>(:final failure) => Result<R>.err(failure),
      };

  R fold<R>(R Function(T value) onOk, R Function(Failure failure) onErr) =>
      switch (this) {
        Ok<T>(:final value) => onOk(value),
        Err<T>(:final failure) => onErr(failure),
      };
}

final class Ok<T> extends Result<T> {
  const Ok(this.value);
  final T value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Ok<T> && other.value == value);

  @override
  int get hashCode => Object.hash('Ok', value);

  @override
  String toString() => 'Ok($value)';
}

final class Err<T> extends Result<T> {
  const Err(this.failure);
  final Failure failure;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Err<T> && other.failure == failure);

  @override
  int get hashCode => Object.hash('Err', failure);

  @override
  String toString() => 'Err($failure)';
}

/// Runs [body] and converts any thrown object into an [UnknownFailure],
/// unless [onError] maps it to something more specific.
Future<Result<T>> guard<T>(
  Future<T> Function() body, {
  Failure Function(Object error, StackTrace stack)? onError,
}) async {
  try {
    return Result.ok(await body());
  } catch (e, s) {
    return Result.err(
      onError?.call(e, s) ?? UnknownFailure(e.toString(), cause: e, stackTrace: s),
    );
  }
}

/// Synchronous counterpart of [guard].
Result<T> guardSync<T>(
  T Function() body, {
  Failure Function(Object error, StackTrace stack)? onError,
}) {
  try {
    return Result.ok(body());
  } catch (e, s) {
    return Result.err(
      onError?.call(e, s) ?? UnknownFailure(e.toString(), cause: e, stackTrace: s),
    );
  }
}
