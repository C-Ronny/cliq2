import 'package:flutter/material.dart';

class AuthTextField extends StatefulWidget {
  final String label;
  final bool obscureText;
  final TextEditingController controller;
  final String? errorText;
  final TextInputType keyboardType;
  final String? Function(String?)? validator;
  final bool autovalidate;
  final Widget? prefixIcon;
  final int? maxLength;
  final FocusNode? focusNode;
  final TextInputAction? textInputAction;
  final Function(String)? onSubmitted;

  const AuthTextField({
    super.key,
    required this.label,
    this.obscureText = false,
    required this.controller,
    this.errorText,
    this.keyboardType = TextInputType.text,
    this.validator,
    this.autovalidate = false,
    this.prefixIcon,
    this.maxLength,
    this.focusNode,
    this.textInputAction,
    this.onSubmitted,
  });

  @override
  State<AuthTextField> createState() => _AuthTextFieldState();
}

class _AuthTextFieldState extends State<AuthTextField> {
  bool _isObscured = true;
  bool _isFocused = false;
  late FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _isObscured = widget.obscureText;
    _focusNode = widget.focusNode ?? FocusNode();
    _focusNode.addListener(_handleFocusChange);
  }

  @override
  void dispose() {
    if (widget.focusNode == null) {
      _focusNode.removeListener(_handleFocusChange);
      _focusNode.dispose();
    }
    super.dispose();
  }

  void _handleFocusChange() {
    setState(() {
      _isFocused = _focusNode.hasFocus;
    });
  }

  void _toggleVisibility() {
    setState(() {
      _isObscured = !_isObscured;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_isFocused || widget.controller.text.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 4),
              child: Text(
                widget.label,
                style: const TextStyle(
                  color: Color(0xFF4CAF50),
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          TextFormField(
            controller: widget.controller,
            obscureText: widget.obscureText ? _isObscured : false,
            keyboardType: widget.keyboardType,
            focusNode: _focusNode,
            maxLength: widget.maxLength,
            textInputAction: widget.textInputAction,
            onFieldSubmitted: widget.onSubmitted,
            style: const TextStyle(color: Colors.white, fontSize: 16),
            decoration: InputDecoration(
              labelText: _isFocused || widget.controller.text.isNotEmpty ? null : widget.label,
              labelStyle: const TextStyle(color: Color(0xFFB3B3B3)),
              errorText: widget.errorText,
              errorStyle: const TextStyle(color: Colors.redAccent),
              filled: true,
              fillColor: const Color(0xFF1E1E1E),
              counterText: "",
              prefixIcon: widget.prefixIcon,
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Color(0xFF4CAF50), width: 1.5),
              ),
              errorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Colors.redAccent, width: 1),
              ),
              focusedErrorBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Colors.redAccent, width: 1.5),
              ),
              suffixIcon: widget.obscureText
                  ? IconButton(
                      icon: Icon(
                        _isObscured ? Icons.visibility_off : Icons.visibility,
                        color: const Color(0xFFB3B3B3),
                        size: 20,
                      ),
                      onPressed: _toggleVisibility,
                    )
                  : null,
            ),
            validator: widget.validator,
            autovalidateMode: widget.autovalidate
                ? AutovalidateMode.onUserInteraction
                : AutovalidateMode.disabled,
          ),
        ],
      ),
    );
  }
}
