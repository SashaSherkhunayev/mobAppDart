import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'game.dart';

void main() {
  runApp(const MainApp());
}

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title: const Align(alignment: .centerLeft, child: Text('Birdle')),
        ),

        body: Center(child: Center(child: const GamePage())),
      ),
    );
  }
}

class Tile extends StatelessWidget {
  const Tile(this.letter, this.hitType, {super.key});

  final String letter;
  final HitType hitType;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: Duration(milliseconds: 500),
      curve: Curves.bounceIn, // NEW
      height: 60,
      width: 60,
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        color: switch (hitType) {
          HitType.hit => Colors.green,
          HitType.partial => Colors.yellow,
          HitType.miss => Colors.grey,
          _ => Colors.white,
        },
      ),
      child: Center(
        child: Text(
          letter.toUpperCase(),
          style: Theme.of(context).textTheme.titleLarge,
        ),
      ),
    );
  }
}

class GamePage extends StatefulWidget {
  const GamePage({super.key});

  @override
  State<GamePage> createState() => _GamePageState();
}

class _GamePageState extends State<GamePage> {
  Game? _game;
  String _currentGuess = '';
  String? _loadError;
  String? _guessError;
  bool _isLoading = true;
  bool _isCheckingGuess = false;

  bool get _isGameOver {
    final game = _game;
    return game == null || game.didWin || game.didLose;
  }

  @override
  void initState() {
    super.initState();
    _loadRussianGame();
  }

  Future<void> _loadRussianGame() async {
    setState(() {
      _isLoading = true;
      _loadError = null;
      _guessError = null;
    });

    try {
      final game = await Game.createRussian();
      if (!mounted) return;

      setState(() {
        _game = game;
        _currentGuess = '';
        _isLoading = false;
      });
    } on RussianWordApiException catch (error) {
      _showLoadError(error.message);
    } on http.ClientException {
      _showLoadError('Не удалось подключиться к словарю. Проверьте интернет.');
    } on TimeoutException {
      _showLoadError('Словарь не ответил вовремя. Попробуйте ещё раз.');
    } on FormatException {
      _showLoadError('Не удалось прочитать список русских слов.');
    }
  }

  void _showLoadError(String message) {
    if (!mounted) return;
    setState(() {
      _loadError = message;
      _isLoading = false;
    });
  }

  Future<bool> _submitGuess(String guess) async {
    final game = _game;
    if (_isCheckingGuess ||
        game == null ||
        game.activeIndex == -1 ||
        game.didWin) {
      return false;
    }

    setState(() {
      _isCheckingGuess = true;
      _guessError = null;
    });

    try {
      final isNoun = await Game.isRussianNounGuess(guess);
      if (!mounted || !identical(game, _game)) return false;

      if (!isNoun) {
        setState(() {
          _guessError = 'Введите существительное, не числительное.';
        });
        return false;
      }

      if (game.activeIndex == -1 || game.didWin) return false;

      setState(() {
        game.guess(guess);
      });
      return true;
    } on RussianWordApiException catch (error) {
      if (mounted) {
        setState(() {
          _guessError = error.message;
        });
      }
      return false;
    } on http.ClientException {
      if (mounted) {
        setState(() {
          _guessError = 'Не удалось проверить слово. Проверьте интернет.';
        });
      }
      return false;
    } on TimeoutException {
      if (mounted) {
        setState(() {
          _guessError = 'Проверка слова не ответила вовремя. Попробуйте ещё раз.';
        });
      }
      return false;
    } on FormatException {
      if (mounted) {
        setState(() {
          _guessError = 'Не удалось прочитать ответ словаря.';
        });
      }
      return false;
    } finally {
      if (mounted) {
        setState(() {
          _isCheckingGuess = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_loadError case final error?) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(error, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _loadRussianGame,
              child: const Text('Повторить'),
            ),
          ],
        ),
      );
    }

    final game = _game;
    if (game == null) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Column(
        children: [
          for (
            var guessIndex = 0;
            guessIndex < game.guesses.length;
            guessIndex++
          )
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var letterIndex = 0; letterIndex < 5; letterIndex++)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 2.5,
                      vertical: 2.5,
                    ),
                    child: Tile(
                      guessIndex == game.activeIndex
                          ? letterIndex < _currentGuess.length
                                ? _currentGuess[letterIndex]
                                : ''
                          : game.guesses[guessIndex][letterIndex].char,
                      guessIndex == game.activeIndex
                          ? HitType.none
                          : game.guesses[guessIndex][letterIndex].type,
                    ),
                  ),
              ],
            ),
          GuessInput(
            onGuessChanged: (String guess) {
              setState(() {
                _currentGuess = guess;
                _guessError = null;
              });
            },
            onSubmitGuess: _submitGuess,
            enabled: !_isGameOver,
          ),
          if (_isCheckingGuess) const LinearProgressIndicator(),
          if (_guessError case final error?)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
                textAlign: TextAlign.center,
              ),
            ),
          if (game.didWin)
            const Text('Вы угадали слово!')
          else if (game.didLose)
            Text('Игра окончена! Загаданное слово: ${game.hiddenWord}.'),
          if (game.didWin || game.didLose)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: FilledButton.icon(
                onPressed: _loadRussianGame,
                icon: const Icon(Icons.refresh),
                label: const Text('Начать новую игру'),
              ),
            ),
        ],
      ),
    );
  }
}

class GuessInput extends StatefulWidget {
  const GuessInput({
    super.key,
    required this.onGuessChanged,
    required this.onSubmitGuess,
    required this.enabled,
  });

  final void Function(String) onGuessChanged;
  final Future<bool> Function(String) onSubmitGuess;
  final bool enabled;

  @override
  State<GuessInput> createState() => _GuessInputState();
}

class _GuessInputState extends State<GuessInput> {
  final TextEditingController _textEditingController = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  bool _isSubmitting = false;

  @override
  void dispose() {
    _textEditingController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _onSubmit() async {
    final guess = _textEditingController.text.trim();
    if (_isSubmitting || !widget.enabled) return;
    if (guess.length != 5) {
      _restoreInputFocus();
      return;
    }

    setState(() {
      _isSubmitting = true;
    });
    try {
      final accepted = await widget.onSubmitGuess(guess);
      if (!mounted) return;
      if (accepted && _textEditingController.text.trim() == guess) {
        _textEditingController.clear();
        widget.onGuessChanged('');
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
        });
        _restoreInputFocus();
      }
    }
  }

  void _restoreInputFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.enabled) {
        _focusNode.requestFocus();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(8.0),
            child: TextField(
              maxLength: 5,
              enabled: widget.enabled,
              focusNode: _focusNode,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp('[а-яА-ЯёЁ]')),
              ],
              decoration: const InputDecoration(
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.all(Radius.circular(35)),
                ),
              ),
              controller: _textEditingController,
              onChanged: widget.onGuessChanged,
              onEditingComplete: () {},
              onSubmitted: (input) {
                _onSubmit();
              },
            ),
          ),
        ),
        IconButton(
          padding: EdgeInsets.zero,
          icon: const Icon(Icons.arrow_circle_up),
          onPressed:
              widget.enabled &&
                  !_isSubmitting &&
                  _textEditingController.text.trim().length == 5
              ? _onSubmit
              : null,
        ),
      ],
    );
  }
}
