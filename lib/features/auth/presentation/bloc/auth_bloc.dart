import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import '../../data/auth_session_store.dart';
import '../../data/datasources/user_data_source.dart';
import '../../data/models/auth_user_model.dart';

part 'auth_event.dart';
part 'auth_state.dart';

/// Owns the waiter session: hydrates it from [AuthSessionStore] on startup,
/// authenticates a PIN via [UserDataSource], and clears it on logout.
/// Registered app-wide (single instance) so the root gate reads one state.
class AuthBloc extends Bloc<AuthEvent, AuthState> {
  final UserDataSource _dataSource;
  final AuthSessionStore _sessionStore;

  AuthBloc(this._dataSource, this._sessionStore) : super(AuthInitial()) {
    on<AuthCheckSession>(_onCheckSession);
    on<AuthLoginRequested>(_onLoginRequested);
    on<AuthLogout>(_onLogout);
  }

  void _onCheckSession(AuthCheckSession event, Emitter<AuthState> emit) {
    emit(AuthChecking());
    final user = _sessionStore.read();
    if (user != null) {
      emit(AuthAuthenticated(user));
    } else {
      emit(AuthUnauthenticated());
    }
  }

  Future<void> _onLoginRequested(
    AuthLoginRequested event,
    Emitter<AuthState> emit,
  ) async {
    emit(AuthAuthenticating());
    try {
      final user = await _dataSource.verifyPasscode(event.passcode.trim());
      if (user == null) {
        emit(const AuthFailure('Invalid PIN'));
        return;
      }
      await _sessionStore.save(user);
      emit(AuthAuthenticated(user));
    } catch (e, st) {
      debugPrint('[auth] login failed: $e');
      debugPrintStack(stackTrace: st, label: '[auth] login');
      emit(const AuthFailure('Could not sign in. Please try again.'));
    }
  }

  Future<void> _onLogout(AuthLogout event, Emitter<AuthState> emit) async {
    await _sessionStore.clear();
    emit(AuthUnauthenticated());
  }
}
