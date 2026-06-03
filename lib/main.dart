import 'package:flutter/material.dart';

import 'my_home.dart';
void main(){
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp  extends StatelessWidget{
  const MyApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme:ThemeData(
        colorScheme: ColorScheme.light(
          brightness: Brightness.light,
          primary:Colors.blueAccent.shade400,
          onPrimary:Colors.white,
          surface:Colors.grey.shade400,
          onSurface:Colors.blue.shade800,
        ),
      ),
      home:MyHome(),
    );
  }
}