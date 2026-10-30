import 'package:agora_rtc_engine/agora_rtc_engine.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

class AgoraCallScreen extends StatefulWidget {
  const AgoraCallScreen({
    super.key,
    required this.appId,
    required this.channelName,
    required this.displayName,
    required this.consultationTitle,
    this.token,
    this.isVideoEnabled = true,
  });

  final String appId;
  final String channelName;
  final String displayName;
  final String consultationTitle;
  final String? token;
  final bool isVideoEnabled;

  @override
  State<AgoraCallScreen> createState() => _AgoraCallScreenState();
}

class _AgoraCallScreenState extends State<AgoraCallScreen> {
  late RtcEngine _engine;
  int? _remoteUid;
  bool _isJoined = false;
  bool _isMuted = false;
  bool _isCameraOff = false;
  String? _errorMessage;
  bool _isInitializing = true;

  @override
  void initState() {
    super.initState();
    _initializeCall();
  }

  Future<void> _initializeCall() async {
    try {
      // Request permissions
      await [Permission.camera, Permission.microphone].request();

      // Create and initialize engine
      _engine = createAgoraRtcEngine();
      await _engine.initialize(
        RtcEngineContext(appId: widget.appId),
      );

      // Enable video
      await _engine.enableVideo();

      // Register event handlers
      _engine.registerEventHandler(
        RtcEngineEventHandler(
          onJoinChannelSuccess: (RtcConnection connection, int elapsed) {
            if (!mounted) return;
            setState(() {
              _isJoined = true;
              _isInitializing = false;
            });
          },
          onUserJoined: (RtcConnection connection, int remoteUid, int elapsed) {
            if (!mounted) return;
            setState(() {
              _remoteUid = remoteUid;
            });
          },
          onUserOffline: (
            RtcConnection connection,
            int remoteUid,
            UserOfflineReasonType reason,
          ) {
            if (!mounted) return;
            setState(() {
              if (_remoteUid == remoteUid) {
                _remoteUid = null;
              }
            });
          },
          onError: (ErrorCodeType err, String msg) {
            if (!mounted) return;
            setState(() {
              _errorMessage = msg.isNotEmpty ? msg : 'Agora error: $err';
              _isInitializing = false;
            });
          },
        ),
      );

      // Set client role
      await _engine.setClientRole(role: ClientRoleType.clientRoleBroadcaster);

      // Start preview if video enabled
      if (widget.isVideoEnabled) {
        await _engine.startPreview();
      }

      // Join channel. Prefer passed token; fall back to empty for test/dev.
      await _engine.joinChannel(
        token: widget.token ?? '',
        channelId: widget.channelName,
        uid: 0,
        options: const ChannelMediaOptions(),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isInitializing = false;
        _errorMessage = e.toString();
      });
    }
  }

  Future<void> _leaveCall() async {
    try {
      await _engine.leaveChannel();
      await _engine.release();
    } catch (_) {}
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _toggleMute() async {
    try {
      final nextState = !_isMuted;
      await _engine.muteLocalAudioStream(nextState);
      if (!mounted) return;
      setState(() {
        _isMuted = nextState;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to toggle microphone: $e')),
      );
    }
  }

  Future<void> _toggleCamera() async {
    try {
      final nextState = !_isCameraOff;
      await _engine.muteLocalVideoStream(nextState);
      await _engine.enableLocalVideo(!nextState);
      if (!mounted) return;
      setState(() {
        _isCameraOff = nextState;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to toggle camera: $e')),
      );
    }
  }

  @override
  void dispose() {
    () async {
      try {
        await _engine.leaveChannel();
        await _engine.release();
      } catch (_) {}
    }();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasRemoteUser = _remoteUid != null;

    return Scaffold(
      backgroundColor: const Color(0xFF0B1220),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0B1220),
        foregroundColor: Colors.white,
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.consultationTitle,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            Text(
              'Room: ${widget.channelName}',
              style: const TextStyle(fontSize: 12, color: Color(0xFF9AA7B8)),
            ),
          ],
        ),
        actions: [
          IconButton(
            onPressed: _leaveCall,
            icon: const Icon(Icons.call_end_rounded, color: Colors.redAccent),
          ),
        ],
      ),
      body: SafeArea(
        child: _errorMessage != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.error_outline, color: Color(0xFFB42318), size: 48),
                      const SizedBox(height: 16),
                      Text(
                        _errorMessage!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white, fontSize: 14, height: 1.5),
                      ),
                      const SizedBox(height: 24),
                      ElevatedButton(
                        onPressed: () => Navigator.of(context).pop(),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFB42318),
                        ),
                        child: const Text('Go Back'),
                      ),
                    ],
                  ),
                ),
              )
            : _isInitializing
                ? const Center(
                    child: CircularProgressIndicator(color: Colors.white),
                  )
                : Column(
                    children: [
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(24),
                            child: Container(
                              color: const Color(0xFF121C2E),
                              child: Stack(
                                children: [
                                  Positioned.fill(
                                    child: hasRemoteUser
                                        ? AgoraVideoView(
                                            controller: VideoViewController.remote(
                                              rtcEngine: _engine,
                                              canvas: VideoCanvas(uid: _remoteUid),
                                              connection: RtcConnection(channelId: widget.channelName),
                                            ),
                                          )
                                        : AgoraVideoView(
                                            controller: VideoViewController(
                                              rtcEngine: _engine,
                                              canvas: const VideoCanvas(uid: 0),
                                            ),
                                          ),
                                  ),
                                  Positioned(
                                    left: 16,
                                    right: 16,
                                    bottom: 16,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                      decoration: BoxDecoration(
                                        color: Colors.black.withValues(alpha: 0.45),
                                        borderRadius: BorderRadius.circular(18),
                                      ),
                                      child: Text(
                                        hasRemoteUser
                                            ? 'Doctor joined. You can speak now.'
                                            : 'Waiting for the doctor to join this consultation.',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                        ),
                                        textAlign: TextAlign.center,
                                      ),
                                    ),
                                  ),
                                  Positioned(
                                    top: 16,
                                    left: 16,
                                    child: _buildStatusChip(
                                      _isJoined ? 'Connected' : 'Connecting',
                                      _isJoined ? const Color(0xFF1B8F5A) : const Color(0xFFE09F3E),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 18),
                        child: Row(
                          children: [
                            Expanded(
                              child: _CallControlButton(
                                icon: _isMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
                                label: _isMuted ? 'Unmute' : 'Mute',
                                backgroundColor: const Color(0xFF1B263B),
                                onTap: _toggleMute,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _CallControlButton(
                                icon: _isCameraOff ? Icons.videocam_off_rounded : Icons.videocam_rounded,
                                label: _isCameraOff ? 'Camera On' : 'Camera Off',
                                backgroundColor: const Color(0xFF1B263B),
                                onTap: widget.isVideoEnabled ? _toggleCamera : null,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _CallControlButton(
                                icon: Icons.call_end_rounded,
                                label: 'Leave',
                                backgroundColor: const Color(0xFFB42318),
                                onTap: _leaveCall,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
      ),
    );
  }

  Widget _buildStatusChip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w700,
          fontSize: 12,
        ),
      ),
    );
  }
}

class _CallControlButton extends StatelessWidget {
  const _CallControlButton({
    required this.icon,
    required this.label,
    required this.backgroundColor,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final Color backgroundColor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final isDisabled = onTap == null;
    return Opacity(
      opacity: isDisabled ? 0.55 : 1,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            color: backgroundColor,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white),
              const SizedBox(height: 6),
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
