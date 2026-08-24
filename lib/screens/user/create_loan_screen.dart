import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../../core/constants/app_colors.dart';
import '../../models/loan_priority.dart';
import '../../providers/auth_provider.dart';
import '../../providers/loan_provider.dart';
import '../../widgets/custom_button.dart';

class CreateLoanScreen extends StatefulWidget {
  const CreateLoanScreen({super.key});

  @override
  State<CreateLoanScreen> createState() => _CreateLoanScreenState();
}

class _CreateLoanScreenState extends State<CreateLoanScreen> {
  final _formKey = GlobalKey<FormState>();
  final _amountController = TextEditingController(text: '5000');

  double _amountSliderValue = 5000.0;
  static const double _minAmount = 500.0;
  static const double _maxAmount = 50000.0;

  int _selectedTenureMonths = 12;
  static const List<int> _availableTenures = [3, 6, 12, 24, 36];

  String _selectedPurpose = 'Personal';
  static const List<String> _purposes = [
    'Personal',
    'Education',
    'Business',
    'Emergency',
    'Home Improvement',
  ];

  LoanPriority _selectedPriority = LoanPriority.medium;

  @override
  void initState() {
    super.initState();
    _amountController.addListener(_onAmountTextChanged);
  }

  @override
  void dispose() {
    _amountController.removeListener(_onAmountTextChanged);
    _amountController.dispose();
    super.dispose();
  }

  void _onAmountTextChanged() {
    final parsed = double.tryParse(_amountController.text.trim());
    if (parsed != null && parsed >= _minAmount && parsed <= _maxAmount) {
      if ((_amountSliderValue - parsed).abs() > 0.01) {
        setState(() {
          _amountSliderValue = parsed;
        });
      }
    }
  }

  void _onSliderChanged(double value) {
    setState(() {
      _amountSliderValue = value;
      _amountController.text = value.toStringAsFixed(0);
    });
  }

  double get _estimatedMonthlyPayment {
    if (_selectedTenureMonths <= 0) return 0.0;
    return _amountSliderValue / _selectedTenureMonths;
  }

  Future<void> _handleSubmit() async {
    if (!_formKey.currentState!.validate()) return;

    FocusScope.of(context).unfocus();

    final authProvider = Provider.of<AuthProvider>(context, listen: false);
    final user = authProvider.currentUser;
    if (user == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('User session invalid. Please log in again.')),
      );
      return;
    }

    final loanProvider = Provider.of<LoanProvider>(context, listen: false);

    final success = await loanProvider.createLoan(
      userId: user.id,
      userName: user.fullName,
      amount: _amountSliderValue,
      tenureMonths: _selectedTenureMonths,
      purpose: _selectedPurpose,
      priority: _selectedPriority,
    );

    if (!mounted) return;

    if (success) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Loan application submitted successfully!'),
          backgroundColor: AppColors.success,
          behavior: SnackBarBehavior.floating,
        ),
      );
      Navigator.of(context).pop();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            loanProvider.errorMessage ?? 'Failed to submit loan request.',
          ),
          backgroundColor: AppColors.error,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final currencyFormatter = NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: 2);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Apply For Loan'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header description
                Text(
                  'Loan Application Form',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: isDark
                        ? AppColors.textDarkPrimary
                        : AppColors.textLightPrimary,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Customize your loan terms and select your processing priority',
                  style: TextStyle(
                    fontSize: 14,
                    color: isDark
                        ? AppColors.textDarkSecondary
                        : AppColors.textLightSecondary,
                  ),
                ),
                const SizedBox(height: 24),

                // 1. Loan Amount Section
                _buildSectionTitle('1. Desired Loan Amount', isDark),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _amountController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.currency_rupee_rounded),
                    suffixText: 'INR',
                    hintText: 'Enter amount (500 - 50,000)',
                    helperText: 'Min: ₹500  •  Max: ₹50,000',
                  ),
                  validator: (val) {
                    if (val == null || val.trim().isEmpty) {
                      return 'Please enter a loan amount';
                    }
                    final num = double.tryParse(val.trim());
                    if (num == null) {
                      return 'Enter a valid number';
                    }
                    if (num < _minAmount || num > _maxAmount) {
                      return 'Amount must be between ₹500 and ₹50,000';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 10),
                Slider(
                  value: _amountSliderValue.clamp(_minAmount, _maxAmount),
                  min: _minAmount,
                  max: _maxAmount,
                  divisions: 99,
                  activeColor: AppColors.primary,
                  inactiveColor: AppColors.primary.withValues(alpha: 0.15),
                  label: '₹${_amountSliderValue.toStringAsFixed(0)}',
                  onChanged: _onSliderChanged,
                ),

                const SizedBox(height: 24),

                // 2. Loan Tenure Section
                _buildSectionTitle('2. Select Tenure (Months)', isDark),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: _availableTenures.map((tenure) {
                    final isSelected = _selectedTenureMonths == tenure;
                    return ChoiceChip(
                      label: Text(
                        '$tenure Months',
                        style: TextStyle(
                          fontWeight:
                              isSelected ? FontWeight.bold : FontWeight.w500,
                          color: isSelected
                              ? Colors.white
                              : (isDark
                                  ? AppColors.textDarkPrimary
                                  : AppColors.textLightPrimary),
                        ),
                      ),
                      selected: isSelected,
                      selectedColor: AppColors.primary,
                      backgroundColor: isDark
                          ? AppColors.darkSurface
                          : const Color(0xFFF1F5F9),
                      onSelected: (selected) {
                        if (selected) {
                          setState(() {
                            _selectedTenureMonths = tenure;
                          });
                        }
                      },
                    );
                  }).toList(),
                ),

                const SizedBox(height: 24),

                // 3. Loan Purpose Section
                _buildSectionTitle('3. Loan Purpose', isDark),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _selectedPurpose,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.category_outlined),
                  ),
                  items: _purposes.map((purpose) {
                    return DropdownMenuItem<String>(
                      value: purpose,
                      child: Text(purpose),
                    );
                  }).toList(),
                  onChanged: (val) {
                    if (val != null) {
                      setState(() {
                        _selectedPurpose = val;
                      });
                    }
                  },
                ),

                const SizedBox(height: 24),

                // 4. Priority Selection
                _buildSectionTitle('4. Processing Priority', isDark),
                const SizedBox(height: 6),
                Text(
                  'Choose priority level based on your urgency',
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark
                        ? AppColors.textDarkSecondary
                        : AppColors.textLightSecondary,
                  ),
                ),
                const SizedBox(height: 12),
                Column(
                  children: LoanPriority.values.map((priority) {
                    final isSelected = _selectedPriority == priority;
                    return Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? priority.backgroundColor
                            : (isDark ? AppColors.darkCard : AppColors.lightCard),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: isSelected
                              ? priority.color
                              : (isDark
                                  ? AppColors.darkBorder
                                  : AppColors.lightBorder),
                          width: isSelected ? 2 : 1,
                        ),
                      ),
                      child: InkWell(
                        onTap: () {
                          setState(() {
                            _selectedPriority = priority;
                          });
                        },
                        borderRadius: BorderRadius.circular(14),
                        child: Padding(
                          padding: const EdgeInsets.all(14.0),
                          child: Row(
                            children: [
                              Icon(
                                isSelected
                                    ? Icons.radio_button_checked_rounded
                                    : Icons.radio_button_off_rounded,
                                color: isSelected
                                    ? priority.color
                                    : (isDark
                                        ? AppColors.textDarkSecondary
                                        : AppColors.textLightSecondary),
                                size: 22,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '${priority.label} Priority',
                                      style: TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.bold,
                                        color: isDark
                                            ? AppColors.textDarkPrimary
                                            : AppColors.textLightPrimary,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      priority.description,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: isDark
                                            ? AppColors.textDarkSecondary
                                            : AppColors.textLightSecondary,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),

                const SizedBox(height: 24),

                // 5. Estimated Monthly Payment Card
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: isDark ? AppColors.darkSurface : const Color(0xFFEFF6FF),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: AppColors.primary.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Column(
                    children: [
                      const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.calculate_outlined,
                              color: AppColors.primary, size: 20),
                          SizedBox(width: 6),
                          Text(
                            'Estimated Repayment Breakdown',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: AppColors.primary,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text(
                        currencyFormatter.format(_estimatedMonthlyPayment),
                        style: const TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w800,
                          color: AppColors.primary,
                        ),
                      ),
                      const Text(
                        'per month (Estimate)',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.textLightSecondary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Calculated based on ₹${NumberFormat.currency(locale: 'en_IN', symbol: '', decimalDigits: 0).format(_amountSliderValue)} divided over $_selectedTenureMonths months.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 11,
                          color: isDark
                              ? AppColors.textDarkSecondary
                              : AppColors.textLightSecondary,
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 32),

                // Submit Button
                Consumer<LoanProvider>(
                  builder: (context, loanProvider, child) {
                    return CustomButton(
                      text: 'Submit Loan Application',
                      isLoading: loanProvider.isLoading,
                      icon: Icons.send_rounded,
                      onPressed: _handleSubmit,
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String title, bool isDark) {
    return Text(
      title,
      style: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.bold,
        color: isDark ? AppColors.textDarkPrimary : AppColors.textLightPrimary,
      ),
    );
  }
}
