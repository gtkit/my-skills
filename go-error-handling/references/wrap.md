# wrap 边界、errors.Join、AsType

```go
// Get 是"增加信息"的层：把驱动错误翻译成业务哨兵，或补上操作名与主键。
func (r *Repo) Get(ctx context.Context, id int64) (*Order, error) {
	var o Order
	err := r.db.QueryRowContext(ctx, "SELECT id FROM orders WHERE id = $1", id).Scan(&o.ID)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, apperror.Wrap(apperror.ErrOrderNotFound, err)
	}
	if err != nil {
		return nil, fmt.Errorf("repo.Order.Get id=%d: %w", id, err)
	}
	return &o, nil
}

// Get 是"纯透传"的层：不 wrap。否则日志里出现 "get order: get order: repo.Order.Get id=1: ..." 的冗余链。
func (s *Service) Get(ctx context.Context, id int64) (*Order, error) {
	return s.repo.Get(ctx, id)
}

// WriteFile 演示 defer Close 的错误合并：f.Close() 在写盘失败时才暴露 ENOSPC，丢掉它等于吞错。
func WriteFile(path string, data []byte) (err error) {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer func() { err = errors.Join(err, f.Close()) }()
	_, err = f.Write(data)
	return err
}

// HTTPStatus 演示 errors.AsType：无需先声明变量再取地址。
func HTTPStatus(err error) int {
	if ae, ok := errors.AsType[*apperror.AppError](err); ok {
		return ae.HTTP
	}
	return apperror.ErrInternal.HTTP
}
```

批处理部分失败不在第一个错误处中断：`errs = append(errs, fmt.Errorf("item %d: %w", id, err))` 后 `return errors.Join(errs...)`；`errors.Is/As` 会遍历 `Unwrap() []error` 树，Join 后仍可定位具体原因。`fmt.Errorf` 允许多个 `%w`（Go 1.20 起）。
