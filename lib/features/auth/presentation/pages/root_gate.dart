import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../../../core/utils/splash_dismisser.dart';
import '../../../home/presentation/pages/home_page.dart';
import '../bloc/auth_bloc.dart';
import 'pin_login_page.dart';

/// The staff console at `/staff`, gated behind a PIN. While the session is being
/// read it shows a loader, an authenticated waiter sees the [StaffHomePage]
/// (Add Order + settings), and everyone else sees the [PinLoginPage]. The PIN
/// is only verifiable in local mode (the verifier edge function); online is
/// unsupported by design.
class RootGate extends StatelessWidget {
  const RootGate({super.key});

  @override
  Widget build(BuildContext context) {
    // No heavy background image on the staff routes — lift the splash on the
    // first painted frame.
    return SplashDismisser(
      child: BlocBuilder<AuthBloc, AuthState>(
        builder: (context, state) {
          if (state is AuthAuthenticated) {
            return const StaffHomePage();
          }
          if (state is AuthInitial || state is AuthChecking) {
            return const _GateLoader();
          }
          return const PinLoginPage();
        },
      ),
    );
  }
}

class _GateLoader extends StatelessWidget {
  const _GateLoader();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xff121212),
      body: Center(
        child: CircularProgressIndicator(
          valueColor: AlwaysStoppedAnimation<Color>(Color(0xfff25125)),
        ),
      ),
    );
  }
}
