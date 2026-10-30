package com.anonymous.Arogion_MVP

import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel
import java.util.TimeZone

class MainActivity : FlutterActivity() {
	private val channelName = "arogion/timezone"

	override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)

		MethodChannel(
			flutterEngine.dartExecutor.binaryMessenger,
			channelName
		).setMethodCallHandler { call, result ->
			when (call.method) {
				"getTimeZone" -> result.success(TimeZone.getDefault().id)
				else -> result.notImplemented()
			}
		}
	}
}
