import UIKit

final class SliderRowView: UIView {

    var onValueChanged: ((Float) -> Void)?
    var onEditingBegan: (() -> Void)?
    var onEditingEnded: (() -> Void)?

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = AppTheme.primaryText
        return label
    }()

    private let valueLabel: UILabel = {
        let label = UILabel()
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        label.textColor = AppTheme.secondaryText
        label.textAlignment = .right
        label.setContentHuggingPriority(.required, for: .horizontal)
        return label
    }()

    let slider: UISlider = {
        let slider = UISlider()
        slider.minimumTrackTintColor = AppTheme.accent
        return slider
    }()

    private let formatter: (Float) -> String

    init(title: String, min: Float, max: Float, value: Float, formatter: @escaping (Float) -> String) {
        self.formatter = formatter
        super.init(frame: .zero)
        titleLabel.text = title
        slider.minimumValue = min
        slider.maximumValue = max
        slider.value = value
        valueLabel.text = formatter(value)
        setupLayout()
        slider.addTarget(self, action: #selector(sliderEditingBegan), for: .touchDown)
        slider.addTarget(self, action: #selector(sliderChanged), for: .valueChanged)
        // Include drag-exit / cancel — UIScrollView often swallows plain touchUpInside.
        slider.addTarget(
            self,
            action: #selector(sliderEditingEnded),
            for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit]
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setValue(_ value: Float, animated: Bool = false) {
        slider.setValue(value, animated: animated)
        valueLabel.text = formatter(value)
    }

    func configure(min: Float, max: Float, value: Float) {
        slider.minimumValue = min
        slider.maximumValue = max
        setValue(value)
    }

    private func setupLayout() {
        translatesAutoresizingMaskIntoConstraints = false
        let header = UIStackView(arrangedSubviews: [titleLabel, valueLabel])
        header.axis = .horizontal
        header.alignment = .center

        let stack = UIStackView(arrangedSubviews: [header, slider])
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private var isEditingSlider = false

    @objc private func sliderEditingBegan() {
        guard !isEditingSlider else { return }
        isEditingSlider = true
        onEditingBegan?()
    }

    @objc private func sliderChanged() {
        valueLabel.text = formatter(slider.value)
        if slider.isTracking, !isEditingSlider {
            isEditingSlider = true
            onEditingBegan?()
        }
        onValueChanged?(slider.value)
        if isEditingSlider, !slider.isTracking {
            isEditingSlider = false
            onEditingEnded?()
        }
    }

    @objc private func sliderEditingEnded() {
        guard isEditingSlider else { return }
        isEditingSlider = false
        onEditingEnded?()
    }
}
